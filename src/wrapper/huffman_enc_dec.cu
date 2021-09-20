/**
 * @file huffman_enc_dec.cu
 * @author Jiannan Tian, Cody Rivera (cjrivera1@crimson.ua.edu)
 * @brief Workflow of Huffman coding.
 * @version 0.1
 * @date 2020-10-24
 * (created) 2020-04-24 (rev) 2021-09-0
 *
 * @copyright (C) 2020 by Washington State University, The University of Alabama, Argonne National Laboratory
 * See LICENSE in top-level directory
 *
 */

#include <cuda_runtime.h>

#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <bitset>
#include <cassert>
#include <cmath>
#include <functional>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <tuple>
#include <type_traits>
#include <vector>

#include "../kernel/codec_huffman.cuh"
#include "../kernel/hist.cuh"
#include "../types.hh"
#include "../type_trait.hh"
#include "../utils.hh"
#include "huffman_enc_dec.cuh"

#ifdef MODULAR_ELSEWHERE
#include "cascaded.hpp"
#include "nvcomp.hpp"
#endif

#if __cplusplus >= 201703L
#define CONSTEXPR constexpr
#else
#define CONSTEXPR
#endif

#define nworker blockDim.x

template <typename Huff>
__global__ void cusz::huffman_enc_concatenate(
    Huff*   in_enc_space,
    Huff*   out_bitstream,
    size_t* sp_entries,
    size_t* sp_uints,
    size_t  chunk_size)
{
    auto len      = sp_uints[blockIdx.x];
    auto sp_entry = sp_entries[blockIdx.x];
    auto dn_entry = chunk_size * blockIdx.x;

    for (auto i = 0; i < (len + nworker - 1) / nworker; i++) {
        auto _tid = threadIdx.x + i * nworker;
        if (_tid < len) *(out_bitstream + sp_entry + _tid) = *(in_enc_space + dn_entry + _tid);
        __syncthreads();
    }
}

template <typename Huff>
void cusz::huffman_process_metadata(
    size_t* _counts,
    size_t* dev_bits,
    size_t  nchunk,
    size_t& num_bits,
    size_t& num_uints)
{
    constexpr auto TYPE_BITCOUNT = sizeof(Huff) * 8;

    auto sp_uints = _counts, sp_bits = _counts + nchunk, sp_entries = _counts + nchunk * 2;

    cudaMemcpy(sp_bits, dev_bits, nchunk * sizeof(size_t), cudaMemcpyDeviceToHost);
    memcpy(sp_uints, sp_bits, nchunk * sizeof(size_t));
    for_each(sp_uints, sp_uints + nchunk, [&](size_t& i) { i = (i + TYPE_BITCOUNT - 1) / TYPE_BITCOUNT; });
    memcpy(sp_entries + 1, sp_uints, (nchunk - 1) * sizeof(size_t));
    for (auto i = 1; i < nchunk; i++) sp_entries[i] += sp_entries[i - 1];  // inclusive scan

    num_bits  = std::accumulate(sp_bits, sp_bits + nchunk, (size_t)0);
    num_uints = std::accumulate(sp_uints, sp_uints + nchunk, (size_t)0);
}

/*
template <typename T>
void draft::UseNvcompZip(T* space, size_t& len)
{
    int*         uncompressed_data;
    const size_t in_bytes = len * sizeof(T);

    cudaMalloc(&uncompressed_data, in_bytes);
    cudaMemcpy(uncompressed_data, space, in_bytes, cudaMemcpyHostToDevice);
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    // 2 layers RLE, 1 Delta encoding, bitpacking enabled
    nvcomp::CascadedCompressor<int> compressor(uncompressed_data, in_bytes / sizeof(int), 2, 1, true);
    const size_t                    temp_size = compressor.get_temp_size();
    void*                           temp_space;
    cudaMalloc(&temp_space, temp_size);
    size_t output_size = compressor.get_max_output_size(temp_space, temp_size);
    void*  output_space;
    cudaMalloc(&output_space, output_size);
    compressor.compress_async(temp_space, temp_size, output_space, &output_size, stream);
    cudaStreamSynchronize(stream);
    // TODO ad hoc; should use original GPU space
    memset(space, 0x0, len * sizeof(T));
    len = output_size / sizeof(T);
    cudaMemcpy(space, output_space, output_size, cudaMemcpyDeviceToHost);

    cudaFree(uncompressed_data);
    cudaFree(temp_space);
    cudaFree(output_space);
    cudaStreamDestroy(stream);
}

template <typename T>
void draft::UseNvcompUnzip(T** d_space, size_t& len)
{
    cudaStream_t stream;
    cudaStreamCreate(&stream);

    nvcomp::Decompressor<int> decompressor(*d_space, len * sizeof(T), stream);
    const size_t              temp_size = decompressor.get_temp_size();
    void*                     temp_space;
    cudaMalloc(&temp_space, temp_size);

    const size_t output_count = decompressor.get_num_elements();
    int*         output_space;
    cudaMalloc((void**)&output_space, output_count * sizeof(int));

    decompressor.decompress_async(temp_space, temp_size, output_space, output_count, stream);

    cudaStreamSynchronize(stream);
    cudaFree(*d_space);

    *d_space = mem::create_CUDA_space<T>((unsigned long)(output_count * sizeof(int)));
    cudaMemcpy(*d_space, output_space, output_count * sizeof(int), cudaMemcpyDeviceToDevice);
    len = output_count * sizeof(int) / sizeof(T);

    cudaFree(output_space);

    cudaStreamDestroy(stream);
    cudaFree(temp_space);
}

*/

template <typename Quant, typename Huff, bool UINTS_KNOWN>
void lossless::HuffmanEncode(
    Huff*   dev_enc_space,
    size_t* dev_bits,
    size_t* dev_uints,
    size_t* dev_entries,
    size_t* host_counts,
    //
    Huff* dev_out_bitstream,
    //
    Quant*  dev_input,
    Huff*   dev_book,
    size_t  len,
    int     chunk_size,
    int     dict_size,
    size_t* ptr_num_bits,
    size_t* ptr_num_uints,
    float&  milliseconds)
{
    auto nchunk = ConfigHelper::get_npart(len, chunk_size);

    if CONSTEXPR (UINTS_KNOWN == false) {
        {
            auto block_dim = HuffmanHelper::BLOCK_DIM_ENCODE;
            auto grid_dim  = ConfigHelper::get_npart(len, block_dim);
            auto t         = new cuda_timer_t;
            t->timer_start();
            cusz::encode_fixedlen_space_cub<Quant, Huff, HuffmanHelper::ENC_SEQUENTIALITY>
                <<<grid_dim, block_dim / HuffmanHelper::ENC_SEQUENTIALITY>>>(dev_input, dev_enc_space, len, dev_book);
            milliseconds += t->timer_end_get_elapsed_time();
            cudaDeviceSynchronize();
            delete t;
        }

        {
            auto block_dim = HuffmanHelper::BLOCK_DIM_DEFLATE;
            auto grid_dim  = ConfigHelper::get_npart(nchunk, block_dim);
            auto t         = new cuda_timer_t;
            t->timer_start();
            cusz::encode_deflate<Huff><<<grid_dim, block_dim>>>(dev_enc_space, len, dev_bits, chunk_size);
            milliseconds += t->timer_end_get_elapsed_time();
            cudaDeviceSynchronize();
            delete t;
        }

        cusz::huffman_process_metadata<Huff>(host_counts, dev_bits, nchunk, *ptr_num_bits, *ptr_num_uints);
        cudaMemcpy(dev_uints, host_counts, nchunk * sizeof(size_t), cudaMemcpyHostToDevice);
        cudaMemcpy(dev_entries, (host_counts + nchunk * 2), nchunk * sizeof(size_t), cudaMemcpyHostToDevice);
    }
    else {
        auto t = new cuda_timer_t;
        t->timer_start();
        cusz::huffman_enc_concatenate<<<nchunk, 128>>>(
            dev_enc_space, dev_out_bitstream, dev_entries, dev_uints, chunk_size);
        milliseconds += t->timer_end_get_elapsed_time();
        cudaDeviceSynchronize();
    }
}

template <typename Quant, typename Huff>
void lossless::HuffmanDecode(
    Huff*           dev_out_bitstream,
    size_t*         dev_bits_entries,
    uint8_t*        dev_revbook,
    Capsule<Quant>* quant,
    size_t          len,
    int             chunk_size,
    size_t          num_uints,
    int             dict_size,
    float&          milliseconds)
{
    auto revbook_nbyte = HuffmanHelper::get_revbook_nbyte<Quant, Huff>(dict_size);
    auto nchunk        = ConfigHelper::get_npart(len, chunk_size);
    auto block_dim     = HuffmanHelper::BLOCK_DIM_DEFLATE;  // = deflating
    auto grid_dim      = ConfigHelper::get_npart(nchunk, block_dim);

    {
        auto t = new cuda_timer_t;
        t->timer_start();
        cusz::Decode<<<grid_dim, block_dim, revbook_nbyte>>>(  //
            dev_out_bitstream, dev_bits_entries, quant->dptr, len, chunk_size, nchunk, dev_revbook,
            (size_t)revbook_nbyte);
        milliseconds += t->timer_end_get_elapsed_time();
        cudaDeviceSynchronize();
        delete t;
    }
}

// TODO mark types using Q/H-byte binding; internally resolve UI8-UI8_2 issue

#define HUFFMAN_ENCODE(Q, H, BOOL)                     \
    template void lossless::HuffmanEncode<Q, H, BOOL>( \
        H*, size_t*, size_t*, size_t*, size_t*, H*, Q*, H*, size_t, int, int, size_t*, size_t*, float&);

// HUFFMAN_ENCODE(UI1, UI4, false)
// HUFFMAN_ENCODE(UI1, UI8, false)
HUFFMAN_ENCODE(UI2, UI4, false)
HUFFMAN_ENCODE(UI2, UI8, false)
HUFFMAN_ENCODE(UI4, UI4, false)
HUFFMAN_ENCODE(UI4, UI8, false)

// HUFFMAN_ENCODE(UI1, UI4, true)
// HUFFMAN_ENCODE(UI1, UI8, true)
HUFFMAN_ENCODE(UI2, UI4, true)
HUFFMAN_ENCODE(UI2, UI8, true)
HUFFMAN_ENCODE(UI4, UI4, true)
HUFFMAN_ENCODE(UI4, UI8, true)

#define HUFFMAN_DECODE(Q, H) \
    template void lossless::HuffmanDecode<Q, H>(H*, size_t*, uint8_t*, Capsule<Q>*, size_t, int, size_t, int, float&);

// HUFFMAN_DECODE(UI1, UI4)
// HUFFMAN_DECODE(UI1, UI8)
HUFFMAN_DECODE(UI2, UI4)
HUFFMAN_DECODE(UI2, UI8)
HUFFMAN_DECODE(UI4, UI4)
HUFFMAN_DECODE(UI4, UI8)