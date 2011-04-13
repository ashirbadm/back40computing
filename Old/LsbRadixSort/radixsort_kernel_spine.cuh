/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * AUTHORS' REQUEST: 
 * 
 * 		If you use|reference|benchmark this code, please cite our Technical 
 * 		Report (http://www.cs.virginia.edu/~dgm4d/papers/RadixSortTR.pdf):
 * 
 *		@TechReport{ Merrill:Sorting:2010,
 *        	author = "Duane Merrill and Andrew Grimshaw",
 *        	title = "Revisiting Sorting for GPGPU Stream Architectures",
 *        	year = "2010",
 *        	institution = "University of Virginia, Department of Computer Science",
 *        	address = "Charlottesville, VA, USA",
 *        	number = "CS2010-03"
 *		}
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 * 
 ******************************************************************************/


/******************************************************************************
 * Top-level histogram/spine scanning kernel. The second kernel in a 
 * radix-sorting digit-place pass. 
 ******************************************************************************/

#pragma once

#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>
#include <b40c/util/io/load_tile.cuh>
#include <b40c/util/io/store_tile.cuh>

#include "b40c_cuda_properties.cuh"
#include "b40c_kernel_utils.cuh"
#include "radixsort_common.cuh"

namespace b40c {
namespace lsb_radix_sort {
namespace spine_scan {


/******************************************************************************
 * Granularity Configuration
 ******************************************************************************/

/**
 * Spine-scan granularity configuration.  This C++ type encapsulates our 
 * kernel-tuning parameters (they are reflected via the static fields).
 *  
 * The kernels are specialized for problem-type, SM-version, etc. by declaring 
 * them with different performance-tuned parameterizations of this type.  By 
 * incorporating this type into the kernel code itself, we guide the compiler in 
 * expanding/unrolling the kernel code for specific architectures and problem 
 * types.    
 */
template <
	typename _ScanType,
	typename _SizeT,
	int _CTA_OCCUPANCY,
	int _LOG_THREADS,
	int _LOG_LOAD_VEC_SIZE,
	int _LOG_LOADS_PER_TILE,
	int _LOG_RAKING_THREADS,
	util::io::ld::CacheModifier _READ_MODIFIER,
	util::io::st::CacheModifier _WRITE_MODIFIER>

struct SpineScanConfig
{
	typedef _ScanType							ScanType;
	typedef _SizeT							SizeT;
	static const int CTA_OCCUPANCY  			= _CTA_OCCUPANCY;
	static const int LOG_THREADS 				= _LOG_THREADS;
	static const int LOG_LOAD_VEC_SIZE  		= _LOG_LOAD_VEC_SIZE;
	static const int LOG_LOADS_PER_TILE 		= _LOG_LOADS_PER_TILE;
	static const int LOG_RAKING_THREADS			= _LOG_RAKING_THREADS;
	static const util::io::ld::CacheModifier READ_MODIFIER = _READ_MODIFIER;
	static const util::io::st::CacheModifier WRITE_MODIFIER = _WRITE_MODIFIER;
};



/******************************************************************************
 * Kernel Configuration  
 ******************************************************************************/

/**
 * A detailed upsweep configuration type that specializes kernel code for a specific 
 * sorting pass.  It encapsulates granularity details derived from the inherited 
 * UpsweepConfigType 
 */
template <typename SpineScanConfigType>
struct SpineScanKernelConfig : SpineScanConfigType
{
	static const int THREADS						= 1 << SpineScanConfigType::LOG_THREADS;

	static const int LOG_WARPS						= SpineScanConfigType::LOG_THREADS - B40C_LOG_WARP_THREADS(__B40C_CUDA_ARCH__);
	static const int WARPS							= 1 << LOG_WARPS;

	static const int LOAD_VEC_SIZE					= 1 << SpineScanConfigType::LOG_LOAD_VEC_SIZE;
	static const int LOADS_PER_TILE					= 1 << SpineScanConfigType::LOG_LOADS_PER_TILE;

	static const int LOG_TILE_ELEMENTS				= SpineScanConfigType::LOG_THREADS +
															SpineScanConfigType::LOG_LOADS_PER_TILE +
															SpineScanConfigType::LOG_LOAD_VEC_SIZE;
	static const int TILE_ELEMENTS					= 1 << LOG_TILE_ELEMENTS;

	// We reduce/scan the elements of a loaded vector in registers, and then place that
	// partial reduction into smem rows for further reduction/scanning

	// We need a two-level grid if (LOG_RAKING_THREADS > LOG_WARP_THREADS).  If so, we
	// back up the primary raking warps with a single warp of raking-threads.
	static const bool TWO_LEVEL_GRID 					= (SpineScanConfigType::LOG_RAKING_THREADS > B40C_LOG_WARP_THREADS(__B40C_CUDA_ARCH__));

	// Primary smem SRTS grid type
	typedef SrtsGrid<
		typename SpineScanConfigType::ScanType,						// Partial type
		SpineScanConfigType::LOG_THREADS,							// Depositing threads (the CTA size)
		SpineScanConfigType::LOG_LOADS_PER_TILE,					// Lanes (the number of loads)
		SpineScanConfigType::LOG_RAKING_THREADS> PrimaryGrid;		// Raking threads

	// Secondary smem SRTS grid type
	typedef SrtsGrid<
		typename SpineScanConfigType::ScanType,						// Partial type
		SpineScanConfigType::LOG_RAKING_THREADS,					// Depositing threads (the primary raking threads)
		0,															// 1 lane (the primary raking threads only make one deposit)
		B40C_LOG_WARP_THREADS(__B40C_CUDA_ARCH__)> SecondaryGrid;	// Raking threads (1 warp)
	

	static const int SMEM_BYTES						= (TWO_LEVEL_GRID) ?
															PrimaryGrid::SMEM_BYTES + SecondaryGrid::SMEM_BYTES :	// two-level smem SRTS
															PrimaryGrid::SMEM_BYTES;								// one-level smem SRTS
};
	
	
	


/******************************************************************************
 * Spine-scan kernel subroutines
 ******************************************************************************/


// Reduce each load in registers and place into smem
template <typename Config> 
struct ReduceVectors
{
	typedef typename Config::ScanType ScanType;
	
	// Next load
	template <int LOAD, int TOTAL_LOADS>
	struct Iterate {
		static __device__ __forceinline__ void Invoke(
			ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
			ScanType *base_partial) 
		{
			// Store partial reduction into SRTS grid
			base_partial[LOAD * Config::PrimaryGrid::LANE_STRIDE] =
				SerialReduce<ScanType, Config::LOAD_VEC_SIZE>::Invoke(data[LOAD]);

			// Next load
			Iterate<LOAD + 1, TOTAL_LOADS>::Invoke(data, base_partial);
		}
	};
	
	// Terminate
	template <int TOTAL_LOADS>
	struct Iterate<TOTAL_LOADS, TOTAL_LOADS> {
		static __device__ __forceinline__ void Invoke(
			ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
			ScanType *base_partial) {} 
	};
	
	// Interface
	static __device__ __forceinline__ void Invoke(
		ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
		ScanType *base_partial)
	{
		Iterate<0, Config::LOADS_PER_TILE>::Invoke(data, base_partial);
	}

};


// Scan each load in registers, seeding from smem partials
template <typename Config> 
struct ScanVectors
{
	typedef typename Config::ScanType ScanType;
	
	// Next load
	template <int LOAD, int TOTAL_LOADS>
	struct Iterate {
		static __device__ __forceinline__ void Invoke(
			ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
			ScanType *base_partial) 
		{
			ScanType exclusive_partial = base_partial[LOAD * Config::PrimaryGrid::LANE_STRIDE];
			SerialScan<ScanType, Config::LOAD_VEC_SIZE>::Invoke(data[LOAD], exclusive_partial);

			// Next load
			Iterate<LOAD + 1, TOTAL_LOADS>::Invoke(data, base_partial);
		}
	};
	
	// Terminate
	template <int TOTAL_LOADS>
	struct Iterate<TOTAL_LOADS, TOTAL_LOADS> {
		static __device__ __forceinline__ void Invoke(
			ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
			ScanType *base_partial) {} 
	};
	
	// Interface
	static __device__ __forceinline__ void Invoke(
		ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE], 
		ScanType *base_partial)
	{
		Iterate<0, Config::LOADS_PER_TILE>::Invoke(data, base_partial);
	}

};



/**
 * Warp rake and scan. Must hold that the number of raking threads in the grid 
 * config type is at most the size of a warp.  (May be less.)
 */
template <typename Grid> 
__device__ __forceinline__ void WarpRakeAndScan(
	typename Grid::PartialType 	*raking_seg,
	typename Grid::PartialType 	warpscan[2][Grid::RAKING_THREADS],
	typename Grid::PartialType 	&carry)
{
	typedef typename Grid::PartialType PartialType;
	
	if (threadIdx.x < Grid::RAKING_THREADS) {
		
		// Raking reduction  
		PartialType partial = SerialReduce<PartialType, Grid::PARTIALS_PER_SEG>::Invoke(raking_seg);
		
		// Warpscan
		PartialType warpscan_total;
		partial = WarpScan<PartialType, Grid::LOG_RAKING_THREADS>::Invoke(
			partial,
			warpscan_total,
			warpscan);
		partial += carry;

		// Raking scan 
		SerialScan<PartialType, Grid::PARTIALS_PER_SEG>::Invoke(raking_seg, partial);

		carry += warpscan_total;			// Increment the CTA's running total by the full tile reduction
	}
}


/**
 * Process a scan tile.
 */
template <typename Config, bool TWO_LEVEL_GRID> struct ProcessTile;


/**
 * Process a scan tile using only a one-level raking grid.  (One warp or smaller of raking threads.)
 */
template <typename Config> 
struct ProcessTile <Config, false>
{
	typedef typename Config::ScanType ScanType;
	typedef typename Config::SizeT SizeT;
	
	__device__ __forceinline__ static void Invoke(
		ScanType 	*primary_base_partial,
		ScanType 	*primary_raking_seg,
		ScanType 	*secondary_base_partial,
		ScanType 	*secondary_raking_seg,
		ScanType 	warpscan[2][Config::PrimaryGrid::RAKING_THREADS],
		ScanType 	*d_data,
		SizeT 		cta_offset,
		ScanType 	&carry)
	{
		// Tile of scan elements
		ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE];
		
		// Load tile
		util::io::LoadTile<Config::LOG_LOADS_PER_TILE, Config::LOG_LOAD_VEC_SIZE, Config::THREADS, Config::READ_MODIFIER, true>::Invoke(
			data, d_data, cta_offset, 0);
		
		// Reduce in registers, place partials in smem
		ReduceVectors<Config>::Invoke(data, primary_base_partial);
		
		__syncthreads();
		
		// Primary rake and scan (guaranteed one warp or fewer raking threads)
		WarpRakeAndScan<Config::PrimaryGrid>(primary_raking_seg, warpscan, carry);
		
		__syncthreads();

		// Extract partials from smem, scan in registers
		ScanVectors<Config>::Invoke(data, primary_base_partial);
		
		// Store tile
		util::io::StoreTile<Config::LOG_LOADS_PER_TILE, Config::LOG_LOAD_VEC_SIZE, Config::THREADS, Config::WRITE_MODIFIER, true>::Invoke(
			data, d_data, cta_offset);
	}
};


/**
 * Process a scan tile using a two-level raking grid.  (More than one warp of raking threads.)
 */
template <typename Config> 
struct ProcessTile <Config, true>
{
	typedef typename Config::ScanType ScanType;
	typedef typename Config::SizeT SizeT;
	
	__device__ __forceinline__ static void Invoke(
		ScanType 	*primary_base_partial,
		ScanType 	*primary_raking_seg,
		ScanType 	*secondary_base_partial,
		ScanType 	*secondary_raking_seg,
		ScanType 	warpscan[2][Config::SecondaryGrid::RAKING_THREADS],
		ScanType 	*d_data,
		SizeT 		cta_offset,
		ScanType 	&carry)
	{
		// Tile of scan elements
		ScanType data[Config::LOADS_PER_TILE][Config::LOAD_VEC_SIZE];
		
		// Load tile
		util::io::LoadTile<Config::LOG_LOADS_PER_TILE, Config::LOG_LOAD_VEC_SIZE, Config::THREADS, Config::READ_MODIFIER, true>::Invoke(
			data, d_data, cta_offset);
		
		// Reduce in registers, place partials in smem
		ReduceVectors<Config>::Invoke(data, primary_base_partial);
		
		__syncthreads();
		
		// Raking reduction in primary grid, place result partial into secondary grid
		if (threadIdx.x < Config::PrimaryGrid::RAKING_THREADS) {
			ScanType partial = SerialReduce<ScanType, Config::PrimaryGrid::PARTIALS_PER_SEG>::Invoke(primary_raking_seg);
			*secondary_base_partial = partial;
		}

		__syncthreads();
		
		// Secondary rake and scan (guaranteed one warp or fewer raking threads)
		WarpRakeAndScan<Config::SecondaryGrid>(secondary_raking_seg, warpscan, carry);
		
		__syncthreads();

		// Raking scan in primary grid seeded by partial from secondary grid
		if (threadIdx.x < Config::PrimaryGrid::RAKING_THREADS) {
			ScanType partial = *secondary_base_partial;
			SerialScan<ScanType, Config::PrimaryGrid::PARTIALS_PER_SEG>::Invoke(primary_raking_seg, partial);
		}

		__syncthreads();

		// Extract partials from smem, scan in registers
		ScanVectors<Config>::Invoke(data, primary_base_partial);
		
		// Store tile
		util::io::StoreTile<Config::LOG_LOADS_PER_TILE, Config::LOG_LOAD_VEC_SIZE, Config::THREADS, Config::WRITE_MODIFIER, true>::Invoke(
			data, d_data, cta_offset);
		
	}
};



/**
 * Spine scan 
 */
template <typename Config>
__device__ __forceinline__ void LsbSpineScan(
	typename Config::ScanType * &d_spine,
	typename Config::SizeT  &spine_elements)
{
	typedef typename Config::ScanType ScanType;
	typedef typename Config::SizeT SizeT;

	// Shared memory pool
	__shared__ unsigned char smem_pool[Config::SMEM_BYTES];
	__shared__ ScanType warpscan[2][B40C_WARP_THREADS(__B40C_CUDA_ARCH__)];
	
	// Exit if we're not the first CTA
	if (blockIdx.x > 0) {
		return;
	}
	
	ScanType 	*primary_grid = reinterpret_cast<ScanType*>(smem_pool);
	ScanType 	*primary_base_partial = Config::PrimaryGrid::BasePartial(primary_grid);
	ScanType 	*primary_raking_seg = 0;

	ScanType 	*secondary_base_partial = 0;
	ScanType 	*secondary_raking_seg = 0;
	
	ScanType carry = 0;
	
	// Initialize partial-placement and raking offset pointers
	if (threadIdx.x < Config::PrimaryGrid::RAKING_THREADS) {

		primary_raking_seg = Config::PrimaryGrid::RakingSegment(primary_grid);

		ScanType *secondary_grid = reinterpret_cast<ScanType*>(smem_pool + Config::PrimaryGrid::SMEM_BYTES);		// Offset by the primary grid
		secondary_base_partial = Config::SecondaryGrid::BasePartial(secondary_grid);
		if (Config::TWO_LEVEL_GRID && (threadIdx.x < Config::SecondaryGrid::RAKING_THREADS)) {
			secondary_raking_seg = Config::SecondaryGrid::RakingSegment(secondary_grid);
		}

		// Initialize warpscan
		if (threadIdx.x < B40C_WARP_THREADS(__B40C_CUDA_ARCH__)) {
			warpscan[0][threadIdx.x] = 0;
		}
	}

	// Scan the spine in tiles
	SizeT cta_offset = 0;
	while (cta_offset < spine_elements) {
		
		ProcessTile<Config, Config::TWO_LEVEL_GRID>::Invoke(
			primary_base_partial,
			primary_raking_seg,
			secondary_base_partial,
			secondary_raking_seg,
			warpscan,
			d_spine,
			cta_offset,
			carry);

		cta_offset += Config::TILE_ELEMENTS;
	}
} 


/**
 * Spine scan kernel entry point
 */
template <typename KernelConfig>
__launch_bounds__ (KernelConfig::THREADS, KernelConfig::CTA_OCCUPANCY)
__global__ void SpineScanKernel(
	typename KernelConfig::ScanType *d_spine,
	typename KernelConfig::SizeT spine_elements)
{
	LsbSpineScan<KernelConfig>(d_spine, spine_elements);
} 


} // namespace scan
} // namespace lsb_radix_sort
} // namespace b40c
