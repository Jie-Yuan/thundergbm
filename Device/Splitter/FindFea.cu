/*
 * DeviceSplitter.cu
 *
 *  Created on: 5 May 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#include <iostream>

#include "DeviceSplitter.h"
#include "DeviceFindFeaKernel.h"
#include "Initiator.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../Memory/SplitNodeMemManager.h"
#include "../Memory/dtMemManager.h"
#include "../Preparator.h"
#include "../Hashing.h"
#include "../DevicePredictorHelper.h"
#include "../DevicePredictor.h"
#include "../KernelConf.h"
#include "../../DeviceHost/MyAssert.h"
#include "../../DeviceHost/SparsePred/DenseInstance.h"

using std::cout;
using std::endl;
using std::make_pair;


/**
 * @brief: efficient best feature finder
 */
void DeviceSplitter::FeaFinderAllNode(vector<SplitPoint> &vBest, vector<nodeStat> &rchildStat, vector<nodeStat> &lchildStat)
{
	int numofSNode = vBest.size();

	GBDTGPUMemManager manager;
	SNGPUManager snManager;
	int tempNumofSN = 0;
	manager.MemcpyDeviceToHost(snManager.m_pCurNumofNode, &tempNumofSN, sizeof(int));
//	cout << "numofSN temp=" << tempNumofSN << endl;
	numofSNode = tempNumofSN;

	int nNumofFeature = manager.m_numofFea;
	PROCESS_ERROR(nNumofFeature > 0);

	//gd and hess short name on GPU memory
	float_point *pGD = manager.m_pGrad;
	float_point *pHess = manager.m_pHess;

	//splittable node information short name on GPU memory
	nodeStat *pSNodeState = manager.m_pSNodeStat;

	//use short names for temporary info on GPU memory
	nodeStat *pTempRChildStat = manager.m_pTempRChildStat;
	float_point *pLastValue = manager.m_pLastValue;

	//use short names for instance info
	int *pInsId = manager.m_pDInsId;
	float_point *pFeaValue = manager.m_pdDFeaValue;
	int *pNumofKeyValue = manager.m_pDNumofKeyValue;

	int maxNumofSplittable = manager.m_maxNumofSplittable;
	//Memory set for best split points (i.e. reset the best splittable points)
	manager.MemcpyHostToDevice(manager.m_pBestPointHost, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);

	//allocate numofFeature*numofSplittabeNode
	manager.allocMemForSNForEachThread(nNumofFeature, manager.m_maxNumofSplittable);
	for(int f = 0; f < nNumofFeature; f++)
		manager.MemcpyDeviceToDevice(pSNodeState, manager.m_pSNodeStatPerThread + f * maxNumofSplittable, sizeof(nodeStat) * maxNumofSplittable);

	KernelConf conf;
	dim3 dimGridThreadForEachFea;
	conf.ComputeBlock(nNumofFeature, dimGridThreadForEachFea);
	int sharedMemSizeEachFea = 1;
	FindFeaSplitValue2<<<dimGridThreadForEachFea, sharedMemSizeEachFea>>>(
									  pNumofKeyValue, manager.m_pFeaStartPos, pInsId, pFeaValue, manager.m_pInsIdToNodeId,
									  manager.m_pTempRChildStatPerThread, pGD, pHess, manager.m_pLastValuePerThread,
									  manager.m_pSNodeStatPerThread, manager.m_pBestSplitPointPerThread,
									  manager.m_pRChildStatPerThread, manager.m_pLChildStatPerThread,
									  manager.m_pSNIdToBuffId, maxNumofSplittable, manager.m_pBuffIdVec, numofSNode,
									  DeviceSplitter::m_lambda, nNumofFeature);

	PickBestFea<<<1, 1>>>(manager.m_pTempRChildStatPerThread, manager.m_pLastValuePerThread, manager.m_pSNodeStatPerThread,
			manager.m_pBestSplitPointPerThread, manager.m_pRChildStatPerThread, manager.m_pLChildStatPerThread,
								numofSNode, nNumofFeature, maxNumofSplittable);

	manager.MemcpyDeviceToDevice(manager.m_pTempRChildStatPerThread, pTempRChildStat, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pLastValuePerThread, pLastValue, sizeof(float_point) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pSNodeStatPerThread, pSNodeState, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pBestSplitPointPerThread, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pRChildStatPerThread, manager.m_pRChildStat, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pLChildStatPerThread, manager.m_pLChildStat, sizeof(nodeStat) * maxNumofSplittable);
}

/**
 * @brief: prediction and compute gradient descent
 */
void DeviceSplitter::ComputeGD(vector<RegTree> &vTree, vector<vector<KeyValue> > &vvInsSparse)
{
	GBDTGPUMemManager manager;
	DevicePredictor pred;
	//get features and store the feature ids in a way that the access is efficient
	DenseInsConverter denseInsConverter(vTree);

	vector<double> v_fPredValue;

	//hash feature id to position id
	int numofUsedFea = denseInsConverter.usedFeaSet.size();
	int *pHashUsedFea = NULL;
	int *pSortedUsedFea = NULL;
	pred.GetUsedFeature(denseInsConverter.usedFeaSet, pHashUsedFea, pSortedUsedFea);

	//for each tree
	int nNumofTree = vTree.size();
	int nNumofIns = manager.m_numofIns;
	PROCESS_ERROR(nNumofIns > 0);

	//copy tree from GPU memory
	#ifdef _COMPARE_HOST
	if(nNumofTree - 1 >= 0)
	{
		SNGPUManager snManager;
		int numofNode = 0;
		manager.MemcpyDeviceToHost(snManager.m_pCurNumofNode, &numofNode, sizeof(int));
		TreeNode *pAllNode = new TreeNode[numofNode];
		manager.MemcpyDeviceToHost(snManager.m_pTreeNode, pAllNode, sizeof(TreeNode) * numofNode);

//		cout << numofNode << " v.s. " << vTree[nNumofTree - 1].nodes.size() << endl;
		//compare each node
		for(int n = 0; n < numofNode; n++)
		{
			if(!(pAllNode[n].nodeId == vTree[nNumofTree - 1].nodes[n]->nodeId
			   && pAllNode[n].featureId == vTree[nNumofTree - 1].nodes[n]->featureId
			   && pAllNode[n].fSplitValue == vTree[nNumofTree - 1].nodes[n]->fSplitValue))
			{
				cout << "node id: " << pAllNode[n].nodeId << " v.s. " << vTree[nNumofTree - 1].nodes[n]->nodeId
					 <<	"; feat id: " << pAllNode[n].featureId << " v.s. " << vTree[nNumofTree - 1].nodes[n]->featureId
					 << "; sp value: " << pAllNode[n].fSplitValue << " v.s. " << vTree[nNumofTree - 1].nodes[n]->fSplitValue
					 << "; rc id: " << pAllNode[n].rightChildId << " v.s. " << vTree[nNumofTree - 1].nodes[n]->rightChildId << endl;
			}
		}
	}
	#endif

	//the last learned tree
	int numofNodeOfLastTree = 0;
	TreeNode *pLastTree = NULL;
	DTGPUMemManager treeManager;
	int numofTreeLearnt = treeManager.m_numofTreeLearnt;
	int treeId = numofTreeLearnt - 1;
	pred.GetTreeInfo(pLastTree, numofNodeOfLastTree, treeId);

	//start prediction
	checkCudaErrors(cudaMemset(manager.m_pTargetValue, 0, sizeof(float_point) * nNumofIns));
	for(int i = 0; i < nNumofIns; i++)
	{
		double fValue = 0;
		manager.MemcpyDeviceToHost(manager.m_pPredBuffer + i, &fValue, sizeof(float_point));

		//start prediction ###############

		vector<double> vDense;
		if(nNumofTree > 0)
		{
			pred.FillDenseIns(i, numofUsedFea);

			//prediction using the last tree
			PROCESS_ERROR(numofUsedFea <= manager.m_maxUsedFeaInTrees);
			assert(pLastTree != NULL);
			PredTarget<<<1, 1>>>(pLastTree, numofNodeOfLastTree, manager.m_pdDenseIns, numofUsedFea,
								 manager.m_pHashFeaIdToDenseInsPos, manager.m_pTargetValue + i, treeManager.m_maxTreeDepth);

			#ifdef _COMPARE_HOST
			//construct dense instance #### now for testing
			denseInsConverter.SparseToDense(vvInsSparse[i], vDense);
			//denseInsConverter.PrintDenseVec(vDense);

			//copy the dense instance to vector for testing
			float_point *pDense = new float_point[numofUsedFea];
			manager.MemcpyDeviceToHost(manager.m_pdDenseIns, pDense, sizeof(float_point) * numofUsedFea);

			bool bDiff = false;
			for(int i = 0; i < numofUsedFea; i++)
			{

				int pos = Hashing::HostGetBufferId(pHashUsedFea, pSortedUsedFea[i], numofUsedFea);
				if(vDense[i] != pDense[pos])
				{
					cout << "different: " << vDense[i] << " v.s. " << pDense[pos] << "\t";
					bDiff = true;
				}

				if(bDiff == true && (i == manager.m_numofFea - 1 || i == vDense.size() - 1))
					cout << endl;

				//vDense.push_back(pDense[i]);
			}

			float_point fTarget = 0;
			manager.MemcpyDeviceToHost(manager.m_pTargetValue + i, &fTarget, sizeof(float_point));

			//host prediction
			for(int t = nNumofTree - 1; t >= 0 && t < nNumofTree; t++)
			{
				int nodeId = vTree[t].GetLeafIdSparseInstance(vDense, denseInsConverter.fidToDensePos);
				fValue += vTree[t][nodeId]->predValue;
			}

			if(fValue != fTarget)
				cout << "Target value diff " << fValue << " v.s. " << fTarget << endl;
			#endif
		}

		v_fPredValue.push_back(fValue);
		manager.MemcpyDeviceToDevice(manager.m_pTargetValue + i, manager.m_pPredBuffer + i, sizeof(float_point));
	}

	if(pHashUsedFea != NULL)
		delete []pHashUsedFea;
	if(pSortedUsedFea != NULL)
		delete []pSortedUsedFea;

	//compute GD
	ComputeGDKernel<<<1, 1>>>(nNumofIns, manager.m_pTargetValue, manager.m_pdTrueTargetValue, manager.m_pGrad, manager.m_pHess);
	//copy splittable nodes to GPU memory
	InitNodeStat<<<1, 1>>>(nNumofIns, manager.m_pGrad, manager.m_pHess,
						   manager.m_pSNodeStat, manager.m_pSNIdToBuffId, manager.m_maxNumofSplittable,
						   manager.m_pBuffIdVec);

	#ifdef _COMPARE_HOST
	//compute host GD
	int nTotal = nNumofIns;
	for(int i = 0; i < nTotal; i++)
	{
		float_point fTrueValue = 0;
		manager.MemcpyDeviceToHost(manager.m_pdTrueTargetValue + i, &fTrueValue, sizeof(float_point));
		m_vGDPair_fixedPos[i].grad = v_fPredValue[i] - fTrueValue;
		m_vGDPair_fixedPos[i].hess = 1;
	}

	//compare GDs
	float_point *pfGrad = new float_point[nNumofIns];
	float_point *pfHess = new float_point[nNumofIns];
	manager.MemcpyDeviceToHost(manager.m_pGrad, pfGrad, sizeof(float_point) * nNumofIns);
	manager.MemcpyDeviceToHost(manager.m_pHess, pfHess, sizeof(float_point) * nNumofIns);
	for(int i = 0; i < nTotal; i++)
	{
		if(m_vGDPair_fixedPos[i].grad != pfGrad[i] || m_vGDPair_fixedPos[i].hess != pfHess[i])
			cout << "diff gd: " << m_vGDPair_fixedPos[i].grad << " v.s. " << pfGrad[i] << endl;
	}
	delete []pfGrad;
	delete []pfHess;

	//root node state of the next tree
	nodeStat rootStat;
	for(int i = 0; i < nTotal; i++)
	{
		rootStat.sum_gd += m_vGDPair_fixedPos[i].grad;
		rootStat.sum_hess += m_vGDPair_fixedPos[i].hess;
	}

	m_nodeStat.clear();
	m_nodeStat.push_back(rootStat);
	mapNodeIdToBufferPos.insert(make_pair(0,0));//node0 in pos0 of buffer
	#endif
}
