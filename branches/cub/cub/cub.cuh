/******************************************************************************
 * 
 * Copyright (c) 2010-2012, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2012, NVIDIA CORPORATION.  All rights reserved.
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
 ******************************************************************************/

/******************************************************************************
 * CUB umbrella include file
 ******************************************************************************/

#pragma once

#include <cub/cta_load.cuh>
#include <cub/cta_progress.cuh>
#include <cub/cta_reduce.cuh>
#include <cub/cta_scan.cuh>
#include <cub/cta_store.cuh>

#include <cub/host/cuda_props.cuh>
#include <cub/host/debug.cuh>
#include <cub/host/kernel_props.cuh>
#include <cub/host/multi_buffer.cuh>
#include <cub/host/spinlock.cuh>

#include <cub/thread_load.cuh>
#include <cub/thread_reduce.cuh>
#include <cub/thread_scan.cuh>
#include <cub/thread_store.cuh>

#include <cub/basic_utils.cuh>
#include <cub/device_props.cuh>
#include <cub/operators.cuh>
#include <cub/ptx_intrinsics.cuh>
#include <cub/tex_vector.cuh>
#include <cub/type_utils.cuh>
