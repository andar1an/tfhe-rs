#ifndef CUDA_INTEGER_BITWISE_OPS_CUH
#define CUDA_INTEGER_BITWISE_OPS_CUH

#include "crypto/keyswitch.cuh"
#include "device.h"
#include "integer.cuh"
#include "integer.h"
#include "pbs/programmable_bootstrap_classic.cuh"
#include "pbs/programmable_bootstrap_multibit.cuh"
#include "polynomial/functions.cuh"
#include "utils/kernel_dimensions.cuh"
#include <omp.h>

template <typename Torus>
__host__ void
host_integer_radix_bitop_kb(cudaStream_t *streams, uint32_t *gpu_indexes,
                            uint32_t gpu_count, Torus *lwe_array_out,
                            Torus *lwe_array_1, Torus *lwe_array_2,
                            int_bitop_buffer<Torus> *mem_ptr, void *bsk,
                            Torus *ksk, uint32_t num_radix_blocks) {

  auto lut = mem_ptr->lut;

  integer_radix_apply_bivariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, lwe_array_out, lwe_array_1, lwe_array_2,
      bsk, ksk, num_radix_blocks, lut, lut->params.message_modulus);
}

template <typename Torus>
__host__ void host_integer_radix_bitnot_kb(
    cudaStream_t *streams, uint32_t *gpu_indexes, uint32_t gpu_count,
    Torus *lwe_array_out, Torus *lwe_array_in, int_bitop_buffer<Torus> *mem_ptr,
    void *bsk, Torus *ksk, uint32_t num_radix_blocks) {

  auto lut = mem_ptr->lut;

  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, lwe_array_out, lwe_array_in, bsk, ksk,
      num_radix_blocks, lut);
}

template <typename Torus>
__host__ void scratch_cuda_integer_radix_bitop_kb(
    cudaStream_t stream, uint32_t gpu_index, int_bitop_buffer<Torus> **mem_ptr,
    uint32_t num_radix_blocks, int_radix_params params, BITOP_TYPE op,
    bool allocate_gpu_memory) {

  cudaSetDevice(gpu_index);
  *mem_ptr = new int_bitop_buffer<Torus>(stream, gpu_index, op, params,
                                         num_radix_blocks, allocate_gpu_memory);
}

#endif
