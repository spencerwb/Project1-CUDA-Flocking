#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

#include "device_launch_parameters.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char* msg, int line = -1) {
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess != err) {
		if (line >= 0) {
			fprintf(stderr, "Line %d: ", line);
		}
		fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
		exit(EXIT_FAILURE);
	}
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
// i think the scene_scale actually represents the distance from the origin to the positive extent of the simulation space
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3* dev_pos;
glm::vec3* dev_vel1;
glm::vec3* dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int* dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int* dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int* dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int* dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
	a = (a + 0x7ed55d16) + (a << 12);
	a = (a ^ 0xc761c23c) ^ (a >> 19);
	a = (a + 0x165667b1) + (a << 5);
	a = (a + 0xd3a2646c) ^ (a << 9);
	a = (a + 0xfd7046c5) + (a << 3);
	a = (a ^ 0xb55a4f09) ^ (a >> 16);
	return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
	thrust::default_random_engine rng(hash((int)(index * time)));
	thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

	return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3* arr, float scale) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		glm::vec3 rand = generateRandomVec3(time, index);
		arr[index].x = scale * rand.x;
		arr[index].y = scale * rand.y;
		arr[index].z = scale * rand.z;
	}
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
	numObjects = N;
	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

	// LOOK-1.2 - This is basic CUDA memory management and error checking.
	// Don't forget to cudaFree in  Boids::endSimulation.
	cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

	cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

	cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

	// LOOK-1.2 - This is a typical CUDA kernel invocation.
	kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
		dev_pos, scene_scale);
	checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

	// LOOK-2.1 computing grid params
	gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance); // doubled because rule distances would be radii
	int halfSideCount = (int)(scene_scale / gridCellWidth) + 1; // i think the scene_scale actually represents the distance from the origin to the positive extent of the simulation space
	gridSideCount = 2 * halfSideCount;

	gridCellCount = gridSideCount * gridSideCount * gridSideCount;
	gridInverseCellWidth = 1.0f / gridCellWidth;
	float halfGridWidth = gridCellWidth * halfSideCount;
	gridMinimum.x -= halfGridWidth;
	gridMinimum.y -= halfGridWidth;
	gridMinimum.z -= halfGridWidth;

	// TODO-2.1 TODO-2.3 - Allocate additional buffers here.
	cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

	cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

	cudaMalloc((void**)&dev_gridCellStartIndices, 16 * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

	cudaMalloc((void**)&dev_gridCellEndIndices, 16 * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

	cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3* pos, float* vbo, float s_scale) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);

	float c_scale = -1.0f / s_scale;

	if (index < N) {
		vbo[4 * index + 0] = pos[index].x * c_scale;
		vbo[4 * index + 1] = pos[index].y * c_scale;
		vbo[4 * index + 2] = pos[index].z * c_scale;
		vbo[4 * index + 3] = 1.0f;
	}
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3* vel, float* vbo, float s_scale) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);

	if (index < N) {
		vbo[4 * index + 0] = vel[index].x + 0.3f;
		vbo[4 * index + 1] = vel[index].y + 0.3f;
		vbo[4 * index + 2] = vel[index].z + 0.3f;
		vbo[4 * index + 3] = 1.0f;
	}
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float* vbodptr_positions, float* vbodptr_velocities) {
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

	kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_pos, vbodptr_positions, scene_scale);
	kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, vbodptr_velocities, scene_scale);

	checkCUDAErrorWithLine("copyBoidsToVBO failed!");

	cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int idx, const glm::vec3* pos, const glm::vec3* vel) {
	
	glm::vec3 thisPos = pos[idx];

	glm::vec3 perceivedCenter(0.f);
	glm::vec3 repulsion(0.f);
	glm::vec3 perceivedVelocity(0.f);

	int neighbors1 = 0;
	int neighbors3 = 0;

	for (int i = 0; i < N; i++) {
		// Rule 1 Cohesion: boids fly towards their local perceived center of mass, which excludes themselves
		if (i != idx && glm::distance(thisPos, pos[i]) < rule1Distance) {
			perceivedCenter += pos[i];
			neighbors1++;
		}

		// Rule 2 Separation: boids try to stay a distance d away from each other
		if (i != idx && glm::distance(thisPos, pos[i]) < rule2Distance) {
			repulsion -= (pos[i] - thisPos);
		}

		// Rule 3 Alignment: boids try to match the speed of surrounding boids
		if (i != idx && glm::distance(thisPos, pos[i]) < rule3Distance) {
			perceivedVelocity += vel[i];
			neighbors3++;
		}
	}

	if (neighbors1 != 0) {
		perceivedCenter /= neighbors1; // compute the perceived center of mass by dividing by the number of neighbors
	}

	if (neighbors3 != 0) {
		perceivedVelocity /= neighbors3; // compute the perceived average velocity by dividing by the number of neighbors
	}

	return ((perceivedCenter - thisPos) * rule1Scale) + (repulsion * rule2Scale) + (perceivedVelocity * rule3Scale);
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3* poss,
	glm::vec3* vels1, glm::vec3* vels2) {
	// Compute a new velocity based on pos and vel1
	int idx = threadIdx.x + (blockIdx.x * blockDim.x);
	if (idx >= N) {
		return;
	}
	glm::vec3 vel = vels1[idx] + computeVelocityChange(N, idx, poss, vels1);
	// Clamp the speed
	float speed = glm::length(vel);
	if (speed > maxSpeed)
		vel = (vel / speed) * maxSpeed;
	// Record the new velocity into vel2. Question: why NOT vel1?
	vels2[idx] = vel;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3* pos, glm::vec3* vel) {
	// Update position by velocity
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	if (index >= N) {
		return;
	}
	glm::vec3 thisPos = pos[index];
	thisPos += vel[index] * dt;

	// Wrap the boids around so we don't lose them
	thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
	thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
	thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

	thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
	thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
	thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

	pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
	return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
	glm::vec3 gridMin, float inverseCellWidth,
	glm::vec3* poss, int* indices, int* gridIndices) {
	// TODO-2.1
	// - Label each boid with the index of its grid cell.
	// - Set up a parallel array of integer indices as pointers to the actual
	//   boid data in pos and vel1/vel2
	int idx = threadIdx.x + (blockIdx.x * blockDim.x);
	if (idx >= N) {
		return;
	}
	glm::vec3 pos = poss[idx];
	glm::ivec3 gridIdx = glm::floor((pos - gridMin) * inverseCellWidth);
	gridIndices[idx] = gridIndex3Dto1D(gridIdx.x, gridIdx.y, gridIdx.z, gridResolution);
	indices[idx] = idx;
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int* intBuffer, int value) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		intBuffer[index] = value;
	}
}

__global__ void kernIdentifyCellStartEnd(int N, int* particleGridIndices,
	int* gridCellStartIndices, int* gridCellEndIndices) {
	// TODO-2.1
	// Identify the start point of each cell in the gridIndices array.
	// This is basically a parallel unrolling of a loop that goes
	// "this index doesn't match the one before it, must be a new cell!"
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}
	// at this point particleGridIndices should be sorted
	int curr = particleGridIndices[index];

	if (index == 0) {
		gridCellStartIndices[curr] = index;
		return;
	}

	int prev = particleGridIndices[index - 1];

	if (curr != prev) {
		gridCellStartIndices[curr] = index;
		gridCellEndIndices[prev] = index - 1;
	}

	// the last value of particleGridIndices will never be assigned
	// to be the end index of the last grid in the particleGridIndices
	// array. thus it must be set manually.
	gridCellEndIndices[particleGridIndices[N - 1]] = N - 1;
}


__device__ glm::vec3 computeVelocityChangeScattered(int N, int gridResolution, int idx, const glm::vec3* pos, const glm::vec3* vel,
	glm::ivec3 minIdx3D, glm::ivec3 maxIdx3D, int* gridCellStartIndices, int* gridCellEndIndices, int* particleArrayIndices) {
	// Rule 1 Cohesion: boids fly towards their local perceived center of mass, which excludes themselves
	glm::vec3 thisPos = pos[idx];

	glm::vec3 perceivedCenter(0.f);
	glm::vec3 repulsion(0.f);
	glm::vec3 perceivedVelocity(0.f);

	int neighbors1 = 0;
	int neighbors3 = 0;

	for (int k = minIdx3D.z; k < maxIdx3D.z; k++) {
		for (int j = minIdx3D.y; j < maxIdx3D.y; j++) {
			for (int i = minIdx3D.x; i < maxIdx3D.x; i++) {
				glm::ivec3 gridIdx3D = glm::ivec3(i, j, k);
				int gridIdx1D = gridIndex3Dto1D(gridIdx3D.x, gridIdx3D.y, gridIdx3D.z, gridResolution);
				int start = gridCellStartIndices[gridIdx1D];
				int end = gridCellEndIndices[gridIdx1D];
				for (int l = start; l < end - start; l++) {
					int thatIdx = particleArrayIndices[l];
					// exclude the boid's own data for velocity calculation
					if (thatIdx == idx) continue;

					glm::vec3 thatPos = pos[thatIdx];
					// Rule 1 Cohesion: boids fly towards their local perceived center of mass
					if (glm::distance(thisPos, thatPos) < rule1Distance) {
						perceivedCenter += thatPos;
						neighbors1++;
					}

					// Rule 2 Separation: boids try to stay a distance d away from each other
					if (glm::distance(thisPos, thatPos) < rule2Distance) {
						repulsion -= (thatPos - thisPos);
					}

					// Rule 3 Alignment: boids try to match the speed of surrounding boids
					if (glm::distance(thisPos, thatPos) < rule3Distance) {
						perceivedVelocity += vel[thatIdx];
						neighbors3++;
					}
				}
			}
		}
	}

	if (neighbors1 != 0) {
		perceivedCenter /= neighbors1; // compute the perceived center of mass by dividing by the number of neighbors
	}

	if (neighbors3 != 0) {
		perceivedVelocity /= neighbors3; // compute the perceived average velocity by dividing by the number of neighbors
	}

	return ((perceivedCenter - thisPos) * rule1Scale * 0.f) + (repulsion * rule2Scale) + (perceivedVelocity * rule3Scale * 0.f);


	//for (int i = 0; i < 9; i++) {
	//	if (neighborCells[i] != -1) {
	//		int start = gridCellStartIndices[neighborCells[i]];
	//		int end = gridCellEndIndices[neighborCells[i]] + 1;
	//		for (int j = start; j < end; j++) {
	//			int iOther = particleArrayIndices[j];
	//			if (iOther != iSelf && glm::distance(posSelf, pos[iOther]) < rule1Distance) {
	//				perceivedCenter += pos[iOther];
	//				neighbors++;
	//			}
	//		}
	//	}
	//}

	//if (neighbors != 0) {
	//	perceivedCenter /= neighbors; // compute the perceived center of mass by dividing by the number of neighbors
	//}
	//glm::vec3 velSelf = (perceivedCenter - posSelf) * rule1Scale;

	//// Rule 2 Separation: boids try to stay a distance d away from each other
	//glm::vec3 repulsion(0.f);
	//for (int i = 0; i < 9; i++) {
	//	if (neighborCells[i] != -1) {
	//		int start = gridCellStartIndices[neighborCells[i]];
	//		int end = gridCellEndIndices[neighborCells[i]] + 1;
	//		for (int j = start; j < end; j++) {
	//			int iOther = particleArrayIndices[j];
	//			if (iOther != iSelf && glm::distance(posSelf, pos[iOther]) < rule1Distance) {
	//				repulsion -= (pos[iOther] - posSelf);
	//			}
	//		}
	//	}
	//}

	//velSelf += (repulsion * rule2Scale);

	//// Rule 3 Alignment: boids try to match the speed of surrounding boids
	//glm::vec3 perceivedVelocity(0.f);
	//neighbors = 0;
	//for (int i = 0; i < 9; i++) {
	//	if (neighborCells[i] != -1) {
	//		int start = gridCellStartIndices[neighborCells[i]];
	//		int end = gridCellEndIndices[neighborCells[i]] + 1;
	//		for (int j = start; j < end; j++) {
	//			int iOther = particleArrayIndices[j];
	//			if (iOther != iSelf && glm::distance(posSelf, pos[iOther]) < rule1Distance) {
	//				perceivedVelocity += vel[iOther];
	//				neighbors++;
	//			}
	//		}
	//	}
	//}

	//if (neighbors != 0) {
	//	perceivedVelocity /= neighbors; // compute the perceived average velocity by dividing by the number of neighbors
	//}
	//velSelf += (perceivedVelocity * rule3Scale);

	//return velSelf;
}

__global__ void kernUpdateVelNeighborSearchScattered(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int* gridCellStartIndices, int* gridCellEndIndices,
	int* particleArrayIndices,
	glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
	// TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
	// the number of boids that need to be checked.
	// - Identify the grid cell that this particle is in
	// - Identify which cells may contain neighbors. This isn't always 8.
	// - For each cell, read the start/end indices in the boid pointer array.
	// - Access each boid in the cell and compute velocity change from
	//   the boids rules, if this boid is within the neighborhood distance.
	// - Clamp the speed change before putting the new speed in vel2
	int idx = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (idx >= N) {
		return;
	}

	float radius = imax(rule1Distance, imax(rule2Distance, rule3Distance));
	glm::vec3 thisPos = pos[idx];

	glm::vec3 gridIdx3D = glm::floor((thisPos - gridMin) * inverseCellWidth);
	int gridIdx1D = gridIndex3Dto1D(gridIdx3D.x, gridIdx3D.y, gridIdx3D.z, gridResolution);

	glm::ivec3 minIdx3D = glm::clamp(glm::ivec3(glm::floor(gridIdx3D - (radius * inverseCellWidth))), glm::ivec3(0), glm::ivec3(gridResolution));
	glm::ivec3 maxIdx3D = glm::clamp(glm::ivec3(glm::floor(gridIdx3D + (radius * inverseCellWidth))), glm::ivec3(0), glm::ivec3(gridResolution));

	glm::vec3 vel = vel1[idx] + computeVelocityChangeScattered(N, gridResolution, idx, pos, vel1, minIdx3D, maxIdx3D, gridCellStartIndices, gridCellEndIndices, particleArrayIndices);
	// Clamp the speed
	float speed = glm::length(vel);
	if (speed > maxSpeed)
		vel = (vel / speed) * maxSpeed;
	// Record the new velocity into vel2. Question: why NOT vel1?
	// since this is all happening in parallel, other threads may have read in the revised information
	// when they should have read the original information
	vel2[idx] = vel;

	vel2[idx] = gridIdx3D / float(gridResolution);
	/*
	float radius = imax(rule1Distance, imax(rule2Distance, rule3Distance));
	glm::vec3 posSelf = pos[index];
	glm::vec3 ind3DSelf = glm::floor((posSelf - gridMin) * inverseCellWidth);
	glm::ivec3 ind3DMin = glm::clamp(glm::ivec3(glm::floor(ind3DSelf - (radius * inverseCellWidth))), glm::ivec3(0), glm::ivec3(gridResolution));
	glm::ivec3 ind3DMax = glm::clamp(glm::ivec3(glm::floor(ind3DSelf + (radius * inverseCellWidth))), glm::ivec3(0), glm::ivec3(gridResolution));

	glm::vec3 perceivedCenter(0.f);
	int neighborsR1 = 0;

	for (int i = ind3DMin.x; i < ind3DMax.x; i++) {
		for (int j = ind3DMin.y; j < ind3DMax.y; j++) {
			for (int k = ind3DMin.z; k < ind3DMax.z; k++) {
				int neighbor1DInd = gridIndex3Dto1D(i, j, k, gridResolution);
				int start = gridCellStartIndices[neighbor1DInd];
				int end = gridCellEndIndices[neighbor1DInd];
				for (int l = start; l <= end; l++) {
					// Rule 1 Cohesion: boids fly towards their local perceived center of mass, which excludes themselves
					for (int i = 0; i < N; i++) {
						if (i != index && glm::distance(posSelf, pos[i]) < rule1Distance) {
							perceivedCenter += pos[i];
							neighborsR1++;
						}
					}

					if (neighborsR1 != 0) {
						perceivedCenter /= neighbors; // compute the perceived center of mass by dividing by the number of neighbors
					}
					glm::vec3 velSelf = (perceivedCenter - posSelf) * rule1Scale;

					// Rule 2 Separation: boids try to stay a distance d away from each other
					glm::vec3 repulsion(0.f);
					neighbors = 0;
					for (int i = 0; i < N; i++) {
						if (i != iSelf && glm::distance(posSelf, pos[i]) < rule2Distance) {
							repulsion -= (pos[i] - posSelf);
							neighbors++;
						}
					}

					velSelf += (repulsion * rule2Scale);

					// Rule 3 Alignment: boids try to match the speed of surrounding boids
					glm::vec3 perceivedVelocity(0.f);
					neighbors = 0;
					for (int i = 0; i < N; i++) {
						if (i != iSelf && glm::distance(posSelf, pos[i]) < rule3Distance) {
							perceivedVelocity += vel[i];
							neighbors++;
						}
					}

					if (neighbors != 0) {
						perceivedVelocity /= neighbors; // compute the perceived average velocity by dividing by the number of neighbors
					}
					velSelf += (perceivedVelocity * rule3Scale);
				}
			}
		}
	}
	*/

	//glm::vec3 neighborDet(0.f);
	//glm::vec3 posSelf = pos[index];
	//glm::vec3 posTemp = glm::fract((pos[index] - gridMin) * inverseCellWidth);

	//float3 posSelfF3 = make_float3(posSelf.x, posSelf.y, posSelf.z);
	//float3 posTempF3 = make_float3(posTemp.x, posTemp.y, posTemp.z);

	//for (int i = 0; i < 3; i++) {
	//  if (posTemp[i] == 0.5f) {
	//    neighborDet[i] = 0.f;
	//  }
	//  else if (posTemp[i] < 0.5f) {
	//    neighborDet[i] = -1.f;
	//  }
	//  else if (posTemp[i] > 0.5f) {
	//    neighborDet[i] = 1.f;
	//  }
	//}

	//float3 nDetF3 = make_float3(neighborDet.x, neighborDet.y, neighborDet.z);

	//glm::vec3 gridMax = gridMin + (gridResolution * cellWidth);
	//float3 gridMaxF3 = make_float3(gridMax.x, gridMax.y, gridMax.z);


	//int neighborCells[9];
	//posTemp = glm::floor(pos[index] - gridMin) * inverseCellWidth;
	//neighborCells[8] = gridIndex3Dto1D(posTemp.x, posTemp.y, posTemp.z, gridResolution);

	//for (int i = 0; i < 2; i++) {
	//  for (int j = 0; j < 2; j++) {
	//    for (int k = 0; k < 2; k++) {
	//      glm::vec3 neighborShift(neighborDet * glm::vec3(i % 2, j % 2, k % 2));
	//      glm::vec3 neighborPt = neighborShift * cellWidth + posSelf;
	//      if (glm::any(glm::lessThan(neighborPt, gridMin)) || glm::any(glm::greaterThan(neighborPt, gridMax))) {
	//        neighborCells[i * 4 + j * 2 + k] = -1;
	//      }
	//      else {
	//        neighborPt = glm::floor(neighborPt - gridMin) * inverseCellWidth;
	//        float3 nPtF3 = make_float3(neighborPt.x, neighborPt.y, neighborPt.z);
	//        neighborCells[i * 4 + j * 2 + k] = gridIndex3Dto1D(neighborPt.x, neighborPt.y, neighborPt.z, gridResolution);
	//      }
	//    }
	//  }
	//}

	//// Compute a new velocity based on pos and vel1
	//glm::vec3 velSelf = vel1[index] + computeVelocityChangeScattered(N, index, pos, vel1, neighborCells, gridCellStartIndices, gridCellEndIndices, particleArrayIndices);
	//// Clamp the speed
	//float speed = glm::length(velSelf);
	//if (speed > maxSpeed)
	//    velSelf = (velSelf / speed) * maxSpeed;
	//// Record the new velocity into vel2. Question: why NOT vel1?
	//float3 velSelfF3 = make_float3(velSelf.x, velSelf.y, velSelf.z);
	//vel2[index] = velSelf;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int* gridCellStartIndices, int* gridCellEndIndices,
	glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
	// TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
	// except with one less level of indirection.
	// This should expect gridCellStartIndices and gridCellEndIndices to refer
	// directly to pos and vel1.
	// - Identify the grid cell that this particle is in
	// - Identify which cells may contain neighbors. This isn't always 8.
	// - For each cell, read the start/end indices in the boid pointer array.
	//   DIFFERENCE: For best results, consider what order the cells should be
	//   checked in to maximize the memory benefits of reordering the boids data.
	// - Access each boid in the cell and compute velocity change from
	//   the boids rules, if this boid is within the neighborhood distance.
	// - Clamp the speed change before putting the new speed in vel2
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
	// TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	// use the 3 boid rules to compute the new velocity of every boid
	kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
	checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");
	// compute the new position based on the computed velocity
	kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
	checkCUDAErrorWithLine("kernUpdatePos failed!");
	// TODO-1.2 ping-pong the velocity buffers
	dev_vel1 = dev_vel2;
	// cudaMemcpy(dev_vel1, dev_vel2, numObjects * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);
	// checkCUDAErrorWithLine("memcpy back failed!");
}

void Boids::stepSimulationScatteredGrid(float dt) {
	// TODO-2.1
	// Uniform Grid Neighbor search using Thrust sort.
	// In Parallel:
	// - label each particle with its array index as well as its grid index.
	//   Use 2x width grids.
	// - Unstable key sort using Thrust. A stable sort isn't necessary, but you
	//   are welcome to do a performance comparison.
	// - Naively unroll the loop for finding the start and end indices of each
	//   cell's data pointers in the array of boid indices
	// - Perform velocity updates using neighbor search
	// - Update positions
	// - Ping-pong buffers as needed
	int N = numObjects;
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize); // inexpensive way of computing the ceiling of the division
	// int gridCellCount;
	// int gridSideCount;
	// float gridCellWidth;
	// float gridInverseCellWidth;
	// glm::vec3 gridMinimum;
	// dev_particleArrayIndices is the sorted array of particle indices by grid index
	kernComputeIndices << <fullBlocksPerGrid, blockSize >> > (N, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
	checkCUDAErrorWithLine("kernComputeIndices failed!");

	// Wrap device vectors in thrust iterators for use with thrust.
	thrust::device_ptr<int> dev_thrust_keys(dev_particleGridIndices);
	thrust::device_ptr<int> dev_thrust_values(dev_particleArrayIndices);
	// thrust::sort_by_key
	thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + numObjects, dev_thrust_values);

	kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(N, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

	kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid, blockSize>>>(N, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
	checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

	kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(N, dt, dev_pos, dev_vel2);
	checkCUDAErrorWithLine("kernUpdatePos failed!");

	dev_vel1 = dev_vel2;
}

void Boids::stepSimulationCoherentGrid(float dt) {
	// TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
	// Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
	// In Parallel:
	// - Label each particle with its array index as well as its grid index.
	//   Use 2x width grids
	// - Unstable key sort using Thrust. A stable sort isn't necessary, but you
	//   are welcome to do a performance comparison.
	// - Naively unroll the loop for finding the start and end indices of each
	//   cell's data pointers in the array of boid indices
	// - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
	//   the particle data in the simulation array.
	//   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
	// - Perform velocity updates using neighbor search
	// - Update positions
	// - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
}

void Boids::endSimulation() {
	cudaFree(dev_vel1);
	cudaFree(dev_vel2);
	cudaFree(dev_pos);

	// TODO-2.1 TODO-2.3 - Free any additional buffers here.
	cudaFree(dev_particleArrayIndices);
	cudaFree(dev_particleGridIndices);
	cudaFree(dev_gridCellStartIndices);
	cudaFree(dev_gridCellEndIndices);
	checkCUDAErrorWithLine("cudaFree failed!");
}

void Boids::unitTest() {
	// LOOK-1.2 Feel free to write additional tests here.

	// test unstable sort
	int* dev_intKeys;
	int* dev_intValues;
	int N = 10;

	std::unique_ptr<int[]>intKeys{ new int[N] };
	std::unique_ptr<int[]>intValues{ new int[N] };

	intKeys[0] = 0; intValues[0] = 0;
	intKeys[1] = 1; intValues[1] = 1;
	intKeys[2] = 0; intValues[2] = 2;
	intKeys[3] = 3; intValues[3] = 3;
	intKeys[4] = 0; intValues[4] = 4;
	intKeys[5] = 2; intValues[5] = 5;
	intKeys[6] = 2; intValues[6] = 6;
	intKeys[7] = 0; intValues[7] = 7;
	intKeys[8] = 5; intValues[8] = 8;
	intKeys[9] = 6; intValues[9] = 9;

	cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

	cudaMalloc((void**)&dev_intValues, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

	std::cout << "before unstable sort: " << std::endl;
	for (int i = 0; i < N; i++) {
		std::cout << "  key: " << intKeys[i];
		std::cout << " value: " << intValues[i] << std::endl;
	}

	// How to copy data to the GPU
	cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
	cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

	// Wrap device vectors in thrust iterators for use with thrust.
	thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
	thrust::device_ptr<int> dev_thrust_values(dev_intValues);
	// LOOK-2.1 Example for using thrust::sort_by_key
	thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

	// How to copy data back to the CPU side from the GPU
	cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
	cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
	checkCUDAErrorWithLine("memcpy back failed!");

	std::cout << "after unstable sort: " << std::endl;
	for (int i = 0; i < N; i++) {
		std::cout << "  key: " << intKeys[i];
		std::cout << " value: " << intValues[i] << std::endl;
	}

	// cleanup
	cudaFree(dev_intKeys);
	cudaFree(dev_intValues);
	checkCUDAErrorWithLine("cudaFree failed!");
	return;
}
