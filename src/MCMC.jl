module MCMC

export runLMEM

using DataFrames
using CategoricalArrays
using StatsModels
using MixedModels
using Distributions,LinearAlgebra #samplers
using StatsBase
using Printf



include("prepMatVec.jl")
include("runTime.jl")
include("mme.jl")
include("samplers.jl")
include("misc.jl")
include("outFiles.jl")

runLMEM = function(formula,userData,nChain,nBurn,nThin;myHints=Dict{Symbol,Any}(),blockThese=[],outFolder="outMCMC",VCV=[],userPedData=[],map=[],genotypes...)
	
	folderHandler(outFolder)

	levelsFR,Ainv,yVec,X,Z,M = prepMatVec.prep(formula,userData,userHints=myHints,path2ped=userPedData,paths2geno=genotypes)

	ycorr,nData,dfE,scaleE,X,iXpX,XKeyPos,b,Z,iVarStr,Zp,zpz,uKeyPos,uKeyPos4Print,nColEachZ,u,varU,scaleZ,dfZ,M,Mp,mpm,BetaKeyPos,BetaKeyPos4Print,beta,regionArray,nRegions,varBeta,scaleM,dfM = mme.getMME!(Ainv,yVec,X,Z,M,levelsFR,blockThese,VCV,map,outFolder)
	
	samplers.runSampler!(ycorr,nData,dfE,scaleE,X,iXpX,XKeyPos,b,Z,iVarStr,Zp,zpz,uKeyPos,uKeyPos4Print,nColEachZ,u,varU,scaleZ,dfZ,M,Mp,mpm,BetaKeyPos,BetaKeyPos4Print,beta,regionArray,nRegions,varBeta,scaleM,dfM,nChain,nBurn,nThin,outFolder)
	
end

end
