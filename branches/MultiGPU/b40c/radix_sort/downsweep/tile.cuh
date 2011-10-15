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
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 * 
 ******************************************************************************/


/******************************************************************************
 * Downsweep tile processing abstraction
 ******************************************************************************/

#pragma once

#include <b40c/util/io/load_tile.cuh>
#include <b40c/util/io/scatter_tile.cuh>

#include <b40c/partition/downsweep/tile.cuh>
#include <b40c/radix_sort/sort_utils.cuh>

namespace b40c {
namespace radix_sort {
namespace downsweep {


/**
 * Tile
 *
 * Derives from partition::downsweep::Tile
 */
template <typename KernelPolicy>
struct Tile :
	partition::downsweep::Tile<
		KernelPolicy,
		Tile<KernelPolicy> >						// This class
{
	//---------------------------------------------------------------------
	// Typedefs and Constants
	//---------------------------------------------------------------------

	typedef typename KernelPolicy::KeyType 					KeyType;
	typedef typename KernelPolicy::ValueType 				ValueType;
	typedef typename KernelPolicy::SizeT 					SizeT;


	//---------------------------------------------------------------------
	// Derived Interface
	//---------------------------------------------------------------------

	/**
	 * Returns the bin into which the specified key is to be placed.
	 */
	template <typename Cta>
	__device__ __forceinline__ int DecodeBin(KeyType key, Cta *cta)
	{
		int bin;
		ExtractKeyBits<
			KeyType,
			KernelPolicy::CURRENT_BIT,
			KernelPolicy::LOG_BINS>::Extract(bin, key);
		return bin;
	}


	/**
	 * Returns whether or not the key is valid.
	 */
	template <int CYCLE, int LOAD, int VEC>
	__device__ __forceinline__ bool IsValid()
	{
		return true;
	}


	/**
	 * Loads keys into the tile, applying bit-twiddling
	 */
	template <typename Cta>
	__device__ __forceinline__ void LoadKeys(
		Cta *cta,
		SizeT cta_offset,
		const SizeT &guarded_elements)
	{
		// Read tile of keys, use -1 if key is out-of-bounds
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE, 				// Number of vector loads (log)
			KernelPolicy::LOG_LOAD_VEC_SIZE,				// Number of items per vector load (log)
			KernelPolicy::THREADS,							// Active threads that will be loading
			KernelPolicy::READ_MODIFIER>					// Cache modifier (e.g., CA/CG/CS/NONE/etc.)
				::template LoadValid<KeyType, KernelPolicy::PreprocessTraits::Preprocess>(
					(KeyType (*)[KernelPolicy::LOAD_VEC_SIZE]) this->keys,
					(KeyType) -1,
					cta->d_in_keys + cta_offset,
					guarded_elements);
	}


	/**
	 * Scatter keys from the tile, applying bit-twiddling
	 */
	template <typename Cta>
	__device__ __forceinline__ void ScatterKeys(
		Cta *cta,
		const SizeT &guarded_elements)
	{
		// Scatter keys to global bin partitions
		util::io::ScatterTile<
			KernelPolicy::TILE_ELEMENTS_PER_THREAD,
			KernelPolicy::THREADS,
			KernelPolicy::WRITE_MODIFIER>::template Scatter<
				KeyType,
				KernelPolicy::PostprocessTraits::Postprocess>(
					cta->d_out_keys,
					(KeyType *) this->keys,
					(SizeT *) this->scatter_offsets,
					guarded_elements);
	}
};


} // namespace downsweep
} // namespace radix_sort
} // namespace b40c
