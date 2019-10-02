/**
 * @file   electric_density_map_cuda_kernel.cu
 * @author Yibo Lin
 * @date   Aug 2018
 */
#include <stdio.h>
#include <math.h>
#include <float.h>
#include "cuda_runtime.h"
#include "utility/src/print.h"
#include "utility/src/Msg.h"
#include "utility/src/utils.cuh"
#include "electric_potential/src/density_ops.cuh"
#include "electric_potential/src/atomic_ops.cuh"

DREAMPLACE_BEGIN_NAMESPACE

template <typename T, typename DensityOp, typename AtomicOp>
__global__ void __launch_bounds__(1024, 8) computeTriangleDensityMap(
    const T *x_tensor, const T *y_tensor,
    const T *node_size_x_clamped_tensor, const T *node_size_y_clamped_tensor,
    const T *offset_x_tensor, const T *offset_y_tensor,
    const T *ratio_tensor,
    const T *bin_center_x_tensor, const T *bin_center_y_tensor,
    const int num_nodes,
    const int num_bins_x, const int num_bins_y,
    const T xl, const T yl, const T xh, const T yh,
    const T half_bin_size_x, const T half_bin_size_y,
    const T bin_size_x, const T bin_size_y,
    const T inv_bin_size_x, const T inv_bin_size_y,
    DensityOp computeDensityFunc, 
    AtomicOp atomicAddOp, 
    typename AtomicOp::type *density_map_tensor,
    const int *sorted_node_map ///< can be NULL if not sorted 
    )
{
    int index = blockIdx.x * blockDim.z + threadIdx.z;
    if (index < num_nodes)
    {
        int i = (sorted_node_map)? sorted_node_map[index] : index;

        // use stretched node size 
        T node_size_x = node_size_x_clamped_tensor[i];
        T node_size_y = node_size_y_clamped_tensor[i];
        T node_x = x_tensor[i] + offset_x_tensor[i];
        T node_y = y_tensor[i] + offset_y_tensor[i];
        T ratio = ratio_tensor[i];

        int bin_index_xl = int((node_x - xl) * inv_bin_size_x);
        int bin_index_xh = int(((node_x + node_size_x - xl) * inv_bin_size_x)) + 1; // exclusive
        bin_index_xl = (bin_index_xl > 0) * bin_index_xl;                           // max(bin_index_xl, 0);
        bin_index_xh = min(bin_index_xh, num_bins_x);

        int bin_index_yl = int((node_y - yl) * inv_bin_size_y);
        int bin_index_yh = int(((node_y + node_size_y - yl) * inv_bin_size_y)) + 1; // exclusive
        bin_index_yl = (bin_index_yl > 0) * bin_index_yl;                           // max(bin_index_yl, 0);
        bin_index_yh = min(bin_index_yh, num_bins_y);

        // update density potential map
        for (int k = bin_index_xl + threadIdx.y; k < bin_index_xh; k += blockDim.y)
        {
            T px = computeDensityFunc(node_x, node_size_x, xl, k, bin_size_x);
            T px_by_ratio = px * ratio;

            for (int h = bin_index_yl + threadIdx.x; h < bin_index_yh; h += blockDim.x)
            {
                T py = computeDensityFunc(node_y, node_size_y, yl, h, bin_size_y);
                T area = px_by_ratio * py;
                atomicAddOp(&density_map_tensor[k * num_bins_y + h], area);
            }
        }
    }
}

/// @brief An unrolled way to compute the density map. 
/// Currently it is not as efficient as computeTriangleDensityMap, 
/// it has the potential to be better. 
/// It is not used for now. 
template <typename T>
__global__ void computeTriangleDensityMapUnroll(
    const T *x_tensor, const T *y_tensor,
    const T *node_size_x_clamped_tensor, const T *node_size_y_clamped_tensor,
    const T *offset_x_tensor, const T *offset_y_tensor,
    const T *ratio_tensor,
    const T *bin_center_x_tensor, const T *bin_center_y_tensor,
    const int num_nodes,
    const int num_bins_x, const int num_bins_y,
    const T xl, const T yl, const T xh, const T yh,
    const T half_bin_size_x, const T half_bin_size_y,
    const T bin_size_x, const T bin_size_y,
    const T inv_bin_size_x, const T inv_bin_size_y,
    T *density_map_tensor,
    const int *sorted_node_map ///< can be NULL if not sorted 
    )
{
    int index = blockIdx.x * blockDim.y + threadIdx.y;
    if (index < num_nodes)
    {
        int i = (sorted_node_map)? sorted_node_map[index] : index;

        T node_size_x = node_size_x_clamped_tensor[i];
        T node_size_y = node_size_y_clamped_tensor[i];
        T node_x = x_tensor[i] + offset_x_tensor[i];
        T node_y = y_tensor[i] + offset_y_tensor[i];
        T ratio = ratio_tensor[i];

        int bin_index_xl = int((node_x - xl) * inv_bin_size_x);
        int bin_index_xh = int(((node_x + node_size_x - xl) * inv_bin_size_x)); // inclusive
        bin_index_xl = (bin_index_xl > 0) * bin_index_xl;                       // max(bin_index_xl, 0);
        bin_index_xh = min(bin_index_xh, num_bins_x - 1);

        int bin_index_yl = int((node_y - yl) * inv_bin_size_y);
        int bin_index_yh = int(((node_y + node_size_y - yl) * inv_bin_size_y)); // inclusive
        bin_index_yl = (bin_index_yl > 0) * bin_index_yl;                       // max(bin_index_yl, 0);
        bin_index_yh = min(bin_index_yh, num_bins_y - 1);

        // update density potential map
        int k, h;

        int cond = ((bin_index_xl == bin_index_xh) << 1) | (bin_index_yl == bin_index_yh);
        switch (cond)
        {
        case 0:
        {
            T px_c = bin_size_x;

            T py_l = yl + bin_index_yl * bin_size_y + bin_size_y - node_y;
            T py_c = bin_size_y;
            T py_h = node_y + node_size_y - (bin_index_yh * bin_size_y + yl);

            T area_xc_yl = px_c * py_l * ratio;
            T area_xc_yc = px_c * py_c * ratio;
            T area_xc_yh = px_c * py_h * ratio;

            k = bin_index_xl;

            if (threadIdx.x == 0)
            {
                T px_l = xl + bin_index_xl * bin_size_x + bin_size_x - node_x;
                T area_xl_yl = px_l * py_l * ratio;
                T area_xl_yc = px_l * py_c * ratio;
                T area_xl_yh = px_l * py_h * ratio;
                h = bin_index_yl;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xl_yl);
                for (++h; h < bin_index_yh; ++h)
                {
                    atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xl_yc);
                }
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xl_yh);
                k += blockDim.x;
            }

            for (k += threadIdx.x; k < bin_index_xh; k += blockDim.x)
            {
                h = bin_index_yl;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xc_yl);
                for (++h; h < bin_index_yh; ++h)
                {
                    atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xc_yc);
                }
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xc_yh);
            }

            if (k == bin_index_xh)
            {
                T px_h = node_x + node_size_x - (bin_index_xh * bin_size_x + xl);
                T area_xh_yl = px_h * py_l * ratio;
                T area_xh_yc = px_h * py_c * ratio;
                T area_xh_yh = px_h * py_h * ratio;
                h = bin_index_yl;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xh_yl);
                for (++h; h < bin_index_yh; ++h)
                {
                    atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xh_yc);
                }
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xh_yh);
            }

            return;
        }
        case 1:
        {
            T py = yl + bin_index_yl * bin_size_y + bin_size_y - node_y;
            h = bin_index_yl;
            k = bin_index_xl;

            if (threadIdx.x == 0)
            {
                T px_l = xl + bin_index_xl * bin_size_x + bin_size_x - node_x;
                T area_xl = px_l * py * ratio;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xl);
                k += blockDim.x;
            }

            T px_c = bin_size_x;
            T area_xc = px_c * py * ratio;
            for (k += threadIdx.x; k < bin_index_xh; k += blockDim.x)
            {
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xc);
            }

            if (k == bin_index_xh)
            {
                T px_h = node_x + node_size_x - (bin_index_xh * bin_size_x + xl);
                T area_xh = px_h * py * ratio;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_xh);
            }

            return;
        }
        case 2:
        {
            T px = xl + bin_index_xl * bin_size_x + bin_size_x - node_x;
            k = bin_index_xl;
            h = bin_index_yl;

            if (threadIdx.x == 0)
            {
                T py_l = yl + bin_index_yl * bin_size_y + bin_size_y - node_y;
                T area_yl = px * py_l * ratio;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_yl);
                h += blockDim.x;
            }

            T py_c = bin_size_y;
            T area_yc = px * py_c * ratio;
            for (h += threadIdx.x; h < bin_index_yh; h += blockDim.x)
            {
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_yc);
            }

            if (h == bin_index_yh)
            {
                T py_h = node_y + node_size_y - (bin_index_yh * bin_size_y + yl);
                T area_yh = px * py_h * ratio;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area_yh);
            }

            return;
        }
        case 3:
        {
            if (threadIdx.x == 0)
            {
                T px = xl + bin_index_xl * bin_size_x + bin_size_x - node_x;
                T py = yl + bin_index_yl * bin_size_y + bin_size_y - node_y;
                T area = px * py * ratio;

                k = bin_index_xl;
                h = bin_index_yl;
                atomicAdd(&density_map_tensor[k * num_bins_y + h], area);
            }
            return;
        }
        default:
            assert(0);
        }
    }
}

template <typename T, typename DensityOp, typename AtomicOp>
__global__ void computeExactDensityMap(
        const T *x_tensor, const T *y_tensor,
        const T *node_size_x_tensor, const T *node_size_y_tensor,
        const T *bin_center_x_tensor, const T *bin_center_y_tensor,
        const int num_nodes,
        const int num_bins_x, const int num_bins_y,
        const T xl, const T yl, const T xh, const T yh,
        const T bin_size_x, const T bin_size_y,
        const int num_impacted_bins_x, const int num_impacted_bins_y,
        bool fixed_node_flag,
        DensityOp computeDensityFunc, 
        AtomicOp atomicAddOp, 
        typename AtomicOp::type *density_map_tensor
        )
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    // rank-one update density map
    if (i < num_nodes * num_impacted_bins_x * num_impacted_bins_y)
    {
        int node_id = i / (num_impacted_bins_x * num_impacted_bins_y);
        int residual_index = i - node_id * num_impacted_bins_x * num_impacted_bins_y;
        // x direction
        int bin_index_xl = int((x_tensor[node_id] - xl) / bin_size_x);
        bin_index_xl = max(bin_index_xl, 0);
        int k = bin_index_xl + int(residual_index / num_impacted_bins_y);
        if (k + 1 > num_bins_x)
        {
            return;
        }
        // y direction
        int bin_index_yl = int((y_tensor[node_id] - yl) / bin_size_y);
        bin_index_yl = max(bin_index_yl, 0);
        int h = bin_index_yl + (residual_index % num_impacted_bins_y);
        if (h + 1 > num_bins_y)
        {
            return;
        }

        T px = computeDensityFunc(x_tensor[node_id], node_size_x_tensor[node_id], bin_center_x_tensor[k], bin_size_x, xl, xh, fixed_node_flag);
        T py = computeDensityFunc(y_tensor[node_id], node_size_y_tensor[node_id], bin_center_y_tensor[h], bin_size_y, yl, yh, fixed_node_flag);
        // still area 
        atomicAddOp(&density_map_tensor[k*num_bins_y+h], px*py); 
    }
}

template <typename T, typename AtomicOp>
int computeTriangleDensityMapCallKernel(
    const T *x_tensor, const T *y_tensor,
    const T *node_size_x_clamped_tensor, const T *node_size_y_clamped_tensor,
    const T *offset_x_tensor, const T *offset_y_tensor,
    const T *ratio_tensor,
    const T *bin_center_x_tensor, const T *bin_center_y_tensor,
    int num_nodes, int num_movable_nodes, int num_filler_nodes,
    const int num_bins_x, const int num_bins_y,
    int num_movable_impacted_bins_x, int num_movable_impacted_bins_y,
    int num_filler_impacted_bins_x, int num_filler_impacted_bins_y,
    const T xl, const T yl, const T xh, const T yh,
    const T bin_size_x, const T bin_size_y,
    AtomicOp atomicAddOp, 
    typename AtomicOp::type *density_map_tensor,
    const int *sorted_node_map)
{
    int thread_count = 64;
    // dim3 blockSize(4, thread_count, 1);
    dim3 blockSize(2, 2, thread_count);

    int block_count = (num_movable_nodes - 1 + thread_count) / thread_count;
    computeTriangleDensityMap<<<block_count, blockSize>>>(
        x_tensor, y_tensor,
        node_size_x_clamped_tensor, node_size_y_clamped_tensor,
        offset_x_tensor, offset_y_tensor,
        ratio_tensor,
        bin_center_x_tensor, bin_center_y_tensor,
        num_movable_nodes,
        num_bins_x, num_bins_y,
        xl, yl, xh, yh,
        bin_size_x / 2, bin_size_y / 2,
        bin_size_x, bin_size_y,
        1 / bin_size_x, 1 / bin_size_y,
        TriangleDensity<T>(), 
        atomicAddOp, 
        density_map_tensor,
        sorted_node_map
        );

    if (num_filler_nodes)
    {
        cudaError_t status;
        cudaStream_t stream_filler;

        status = cudaStreamCreate(&stream_filler);
        if (status != cudaSuccess)
        {
            printf("cudaStreamCreate failed for stream_filler\n");
            fflush(stdout);
            return 1;
        }

        int num_physical_nodes = num_nodes - num_filler_nodes;
        block_count = (num_filler_nodes - 1 + thread_count) / thread_count;
        computeTriangleDensityMap<<<block_count, blockSize, 0, stream_filler>>>(
            x_tensor + num_physical_nodes, y_tensor + num_physical_nodes,
            node_size_x_clamped_tensor + num_physical_nodes, node_size_y_clamped_tensor + num_physical_nodes,
            offset_x_tensor + num_physical_nodes, offset_y_tensor + num_physical_nodes,
            ratio_tensor + num_physical_nodes,
            bin_center_x_tensor, bin_center_y_tensor,
            num_filler_nodes,
            num_bins_x, num_bins_y,
            xl, yl, xh, yh,
            bin_size_x / 2, bin_size_y / 2,
            bin_size_x, bin_size_y,
            1 / bin_size_x, 1 / bin_size_y,
            TriangleDensity<T>(), 
            atomicAddOp, 
            density_map_tensor, 
            NULL
            );

        status = cudaStreamDestroy(stream_filler);
        if (status != cudaSuccess)
        {
            printf("stream_filler destroy failed\n");
            fflush(stdout);
            return 1;
        }
    }

    return 0; 
}

template <typename T, typename V>
__global__ void copyScaleArray(T* dst, V* src, T scale_factor, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
    {
        dst[i] = src[i]*scale_factor; 
    }
}

template <typename T>
int computeTriangleDensityMapCudaLauncher(
    const T *x_tensor, const T *y_tensor,
    const T *node_size_x_clamped_tensor, const T *node_size_y_clamped_tensor,
    const T *offset_x_tensor, const T *offset_y_tensor,
    const T *ratio_tensor,
    const T *bin_center_x_tensor, const T *bin_center_y_tensor,
    int num_nodes, int num_movable_nodes, int num_filler_nodes,
    const int num_bins_x, const int num_bins_y,
    int num_movable_impacted_bins_x, int num_movable_impacted_bins_y,
    int num_filler_impacted_bins_x, int num_filler_impacted_bins_y,
    const T xl, const T yl, const T xh, const T yh,
    const T bin_size_x, const T bin_size_y,
    bool deterministic_flag, 
    T *density_map_tensor,
    const int *sorted_node_map)
{
    if (deterministic_flag) // deterministic implementation using unsigned long as fixed point number 
    {
        // total die area 
        double diearea = (xh-xl)*(yh-yl); 
        int integer_bits = max((int)ceil(log2(diearea))+1, 32);
        int fraction_bits = max(64 - integer_bits, 0); 
        unsigned long long int scale_factor = (1UL << fraction_bits); 
        int num_bins = num_bins_x*num_bins_y;
        unsigned long long int* scaled_density_map_tensor = NULL; 
        allocateCUDA(scaled_density_map_tensor, num_bins, unsigned long long int); 

        AtomicAdd<unsigned long long int> atomicAddOp (scale_factor); 

        int thread_count = 512; 
        copyScaleArray<<<(num_bins + thread_count - 1) / thread_count, thread_count>>>(scaled_density_map_tensor, density_map_tensor, scale_factor, num_bins);
        computeTriangleDensityMapCallKernel<T, decltype(atomicAddOp)>(
                x_tensor, y_tensor,
                node_size_x_clamped_tensor, node_size_y_clamped_tensor,
                offset_x_tensor, offset_y_tensor,
                ratio_tensor,
                bin_center_x_tensor, bin_center_y_tensor,
                num_nodes, num_movable_nodes, num_filler_nodes,
                num_bins_x, num_bins_y,
                num_movable_impacted_bins_x, num_movable_impacted_bins_y,
                num_filler_impacted_bins_x, num_filler_impacted_bins_y,
                xl, yl, xh, yh,
                bin_size_x, bin_size_y,
                atomicAddOp, 
                scaled_density_map_tensor,
                sorted_node_map
                );
        copyScaleArray<<<(num_bins + thread_count - 1) / thread_count, thread_count>>>(density_map_tensor, scaled_density_map_tensor, T(1.0/scale_factor), num_bins);

        destroyCUDA(scaled_density_map_tensor);
    }
    else 
    {
        AtomicAdd<T> atomicAddOp; 

        computeTriangleDensityMapCallKernel<T, decltype(atomicAddOp)>(
                x_tensor, y_tensor,
                node_size_x_clamped_tensor, node_size_y_clamped_tensor,
                offset_x_tensor, offset_y_tensor,
                ratio_tensor,
                bin_center_x_tensor, bin_center_y_tensor,
                num_nodes, num_movable_nodes, num_filler_nodes,
                num_bins_x, num_bins_y,
                num_movable_impacted_bins_x, num_movable_impacted_bins_y,
                num_filler_impacted_bins_x, num_filler_impacted_bins_y,
                xl, yl, xh, yh,
                bin_size_x, bin_size_y,
                atomicAddOp, 
                density_map_tensor,
                sorted_node_map
                );
    }

    return 0;
}

template <typename T, typename AtomicOp>
int computeExactDensityMapCallKernel(
        const T *x_tensor, const T *y_tensor,
        const T *node_size_x_tensor, const T *node_size_y_tensor,
        const T *bin_center_x_tensor, const T *bin_center_y_tensor,
        const int num_nodes,
        const int num_bins_x, const int num_bins_y,
        const int num_impacted_bins_x, const int num_impacted_bins_y,
        const T xl, const T yl, const T xh, const T yh,
        const T bin_size_x, const T bin_size_y,
        bool fixed_node_flag,
        AtomicOp atomicAddOp, 
        typename AtomicOp::type *density_map_tensor)
{
    int thread_count = 512;
    int block_count = (num_nodes * num_impacted_bins_x * num_impacted_bins_y - 1 + thread_count) / thread_count;

    computeExactDensityMap<<<block_count, thread_count>>>(
        x_tensor, y_tensor,
        node_size_x_tensor, node_size_y_tensor,
        bin_center_x_tensor, bin_center_y_tensor,
        num_nodes,
        num_bins_x, num_bins_y,
        xl, yl, xh, yh,
        bin_size_x, bin_size_y,
        num_impacted_bins_x, num_impacted_bins_y,
        fixed_node_flag,
        ExactDensity<T>(), 
        atomicAddOp, 
        density_map_tensor);

    return 0;
}

template <typename T>
int computeExactDensityMapCudaLauncher(
    const T *x_tensor, const T *y_tensor,
    const T *node_size_x_tensor, const T *node_size_y_tensor,
    const T *bin_center_x_tensor, const T *bin_center_y_tensor,
    const int num_nodes,
    const int num_bins_x, const int num_bins_y,
    const int num_impacted_bins_x, const int num_impacted_bins_y,
    const T xl, const T yl, const T xh, const T yh,
    const T bin_size_x, const T bin_size_y,
    bool fixed_node_flag,
    bool deterministic_flag, 
    T *density_map_tensor)
{
    if (deterministic_flag) // deterministic implementation using unsigned long as fixed point number 
    {
        // total die area 
        double diearea = (xh-xl)*(yh-yl); 
        int integer_bits = max((int)ceil(log2(diearea))+1, 32);
        int fraction_bits = max(64 - integer_bits, 0); 
        unsigned long long int scale_factor = (1UL << fraction_bits); 
        // Yibo: usually exact is only invoked once, so I put the message here 
        // If it prints too many message, comment it out
        dreamplacePrint(kDEBUG, "deterministic mode: integer %d bits, fraction %d bits, scale factor %llu\n", integer_bits, fraction_bits, scale_factor);
        int num_bins = num_bins_x*num_bins_y;
        unsigned long long int* scaled_density_map_tensor = NULL; 
        allocateCUDA(scaled_density_map_tensor, num_bins, unsigned long long int); 

        AtomicAdd<unsigned long long int> atomicAddOp (scale_factor); 

        int thread_count = 512; 
        copyScaleArray<<<(num_bins + thread_count - 1) / thread_count, thread_count>>>(scaled_density_map_tensor, density_map_tensor, scale_factor, num_bins);
        computeExactDensityMapCallKernel<T, decltype(atomicAddOp)>(
                x_tensor, y_tensor,
                node_size_x_tensor, node_size_y_tensor,
                bin_center_x_tensor, bin_center_y_tensor,
                num_nodes, 
                num_bins_x, num_bins_y,
                num_impacted_bins_x, num_impacted_bins_y, 
                xl, yl, xh, yh,
                bin_size_x, bin_size_y,
                fixed_node_flag, 
                atomicAddOp, 
                scaled_density_map_tensor
                );
        copyScaleArray<<<(num_bins + thread_count - 1) / thread_count, thread_count>>>(density_map_tensor, scaled_density_map_tensor, T(1.0/scale_factor), num_bins);

        destroyCUDA(scaled_density_map_tensor);
    }
    else 
    {
        AtomicAdd<T> atomicAddOp; 

        computeExactDensityMapCallKernel<T, decltype(atomicAddOp)>(
                x_tensor, y_tensor,
                node_size_x_tensor, node_size_y_tensor,
                bin_center_x_tensor, bin_center_y_tensor,
                num_nodes, 
                num_bins_x, num_bins_y,
                num_impacted_bins_x, num_impacted_bins_y, 
                xl, yl, xh, yh,
                bin_size_x, bin_size_y,
                fixed_node_flag, 
                atomicAddOp, 
                density_map_tensor
                );
    }

    return 0;
}

#define REGISTER_KERNEL_LAUNCHER(T)                                                   \
    int instantiateComputeTriangleDensityMapLauncher(                                 \
        const T *x_tensor, const T *y_tensor,                                         \
        const T *node_size_x_clamped_tensor, const T *node_size_y_clamped_tensor,     \
        const T *offset_x_tensor, const T *offset_y_tensor,                           \
        const T *ratio_tensor,                                                        \
        const T *bin_center_x_tensor, const T *bin_center_y_tensor,                   \
        const int num_nodes, const int num_movable_nodes, const int num_filler_nodes, \
        const int num_bins_x, const int num_bins_y,                                   \
        const int num_movable_impacted_bins_x, const int num_movable_impacted_bins_y, \
        const int num_filler_impacted_bins_x, const int num_filler_impacted_bins_y,   \
        const T xl, const T yl, const T xh, const T yh,                               \
        const T bin_size_x, const T bin_size_y,                                       \
        bool deterministic_flag,                                                      \
        T *density_map_tensor,                                                        \
        const int *sorted_node_map)                                                   \
    {                                                                                 \
        return computeTriangleDensityMapCudaLauncher(                                 \
            x_tensor, y_tensor,                                                       \
            node_size_x_clamped_tensor, node_size_y_clamped_tensor,                   \
            offset_x_tensor, offset_y_tensor,                                         \
            ratio_tensor,                                                             \
            bin_center_x_tensor, bin_center_y_tensor,                                 \
            num_nodes, num_movable_nodes, num_filler_nodes,                           \
            num_bins_x, num_bins_y,                                                   \
            num_movable_impacted_bins_x, num_movable_impacted_bins_y,                 \
            num_filler_impacted_bins_x, num_filler_impacted_bins_y,                   \
            xl, yl, xh, yh,                                                           \
            bin_size_x, bin_size_y,                                                   \
            deterministic_flag,                                                       \
            density_map_tensor,                                                       \
            sorted_node_map);                                                         \
    }                                                                                 \
                                                                                      \
    int instantiateComputeExactDensityMapLauncher(                                    \
        const T *x_tensor, const T *y_tensor,                                         \
        const T *node_size_x_tensor, const T *node_size_y_tensor,                     \
        const T *bin_center_x_tensor, const T *bin_center_y_tensor,                   \
        const int num_nodes,                                                          \
        const int num_bins_x, const int num_bins_y,                                   \
        const int num_impacted_bins_x, const int num_impacted_bins_y,                 \
        const T xl, const T yl, const T xh, const T yh,                               \
        const T bin_size_x, const T bin_size_y,                                       \
        bool fixed_node_flag,                                                         \
        bool deterministic_flag,                                                      \
        T *density_map_tensor)                                                        \
    {                                                                                 \
        return computeExactDensityMapCudaLauncher(                                    \
            x_tensor, y_tensor,                                                       \
            node_size_x_tensor, node_size_y_tensor,                                   \
            bin_center_x_tensor, bin_center_y_tensor,                                 \
            num_nodes,                                                                \
            num_bins_x, num_bins_y,                                                   \
            num_impacted_bins_x, num_impacted_bins_y,                                 \
            xl, yl, xh, yh,                                                           \
            bin_size_x, bin_size_y,                                                   \
            fixed_node_flag,                                                          \
            deterministic_flag,                                                       \
            density_map_tensor);                                                      \
    }

REGISTER_KERNEL_LAUNCHER(float);
REGISTER_KERNEL_LAUNCHER(double);

DREAMPLACE_END_NAMESPACE
