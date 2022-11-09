module mme


using Distributions, LinearAlgebra
using StatsBase
using Printf
using CSV
using DataFrames
using DataStructures
using PrettyTables

include("outFiles.jl")
include("misc.jl")
include("runTime.jl")

include("functions.jl")
using .functions

export getMME!

#define type for priorVCV to include Expression :(1|Dam)  or Symbol (:Dam)
ExprOrSymbol = Union{Expr,Symbol}


#main sampler
function getMME!(iA,iGRel,Y,X,Z,M,levelDict,blocks,priorVCV,summaryStat,outPut)
		
        #some info
	nRand = length(Z)
	nColEachZ    = OrderedDict(z => size(Z[z],2) for z in keys(Z))
	nData = length(Y)
	nMarkerSets = length(M)
        #initial computations and settings
	ycorr = deepcopy(Y)

	priorVCV = convert(Dict{ExprOrSymbol, Any},priorVCV)	
	
	### X and b
	levelsX = levelDict[:levelsFE]
	
	#==BLOCK FIXED EFFECTS.
	Order of blocks is as definde by the user
	Order of variables within blocks is always the same as in the model definition, not defined by the user in each block.
	==#
	for b in blocks
		getThese = intersect(collect(keys(X)), b)
		X[Tuple(getThese)] = hcat(getindex.(Ref(X), getThese)...)
		levelsX[Tuple(getThese)] = vcat(getindex.(Ref(levelsX), getThese)...)
		for d in getThese
			delete!(X,d)
			delete!(levelsX,d)
		end
	end
	
	##This is not really nFix, but the "blocks" of fixed effects
        nFix  = length(X)
	
	#not a dictionary anymore, and consistent with possible new order.
	levelsX = hcat(vcat([isa(value,String) ? value : vcat(value...) for (key, value) in levelsX]...)...)
	
	#Key positions of variablese and blocks for speed. b is an array of arrays.
        XKeyPos = OrderedDict{Any,Int64}()
        [XKeyPos[collect(keys(X))[i]]=i for i in 1:length(keys(X))]
	        
	##make iXpX, Z', zpz (for uncor)
        iXpX = deepcopy(X)
	rhsX = deepcopy(X)
	[rhsX[xSet] = zeros(size(X[xSet],2),size(X[xSet],2)) for xSet in keys(X)]

	println("rhsX: $rhsX")	

        for x in keys(X)
		XpX = X[x]'X[x]

		##
                if x in keys(summaryStat)
	                XpX += inv(summaryStat[x].v)
			rhsX[x] += inv(summaryStat[x].v)*(summaryStat[x].m)
                end
                ##

		if isa(XpX,Matrix{Float64}) 
			XpX += Matrix(I*minimum(abs.(diag(XpX)./10000)),size(XpX))
			#XpX += Matrix(I*minimum(abs.(diag(XpX)./size(X[x],1))),size(XpX))
		end
               	iXpX[x] = inv(XpX)
        end
	
        ##make b and u arrays
        b = Array{Array{Float64, 1},1}(undef,0)
        ##counts columns per effect
        for xSet in keys(X)
                nCol = size(X[xSet],2)
                push!(b,fill(0.0,nCol))
        end

	#set up for E.
						
	#no inverse implemented yet!
	if haskey(priorVCV,:e)	
		if ismissing(priorVCV[:e].str) || priorVCV[:e].str=="I" 
				printstyled("prior var-cov structure for \"e\" is either empty or \"I\" was given. An identity matrix will be used\n"; color = :green)
				strE = Matrix(1.0I,nData,nData)
				priorVCV[:e] = Random("I",priorVCV[:e].m,priorVCV[:e].v)
		elseif priorVCV[:e].str=="D"
				strE = D ##no inverse  yet
				error("var-cov structure \"D\" has not been implemented yet")
				printstyled("prior var-cov structure for \"e\" is \"D\". User provided \"D\" matrix (d_ii = 1/w_ii) will be used\n"; color = :green)
		else 
				error("provide a valid prior var-cov structure (\"I\", \"D\" or leave it empty \"[]\") for \"e\" ")
		end
	else	
		printstyled("prior var-cov for \"e\" is fully  empty. An identity matrix will be used with mean=0 and variance=100\n"; color = :green)
		strE = Matrix(1.0I,nData,nData)
		#just add to priors
		priorVCV[:e] = Random("I",0,100)
	end
								
	#parameters for priors
        dfE = 4.0
 	       
	if priorVCV[:e].v==0.0
		priorVCV[:e].v  = 0.0005
       		scaleE     = 0.0005
        else
       		scaleE    = priorVCV[:e].v*(dfE-2.0)/dfE    
   	end


	#### New u
	
	#key positions for each effect in u, for speed. Order of matrices in Z are preserved here.
					
        uKeyPos = OrderedDict{Any,Int64}()
        for zSet in keys(Z)
		pos = findall(x->x==zSet, collect(keys(Z)))[]
                uKeyPos[zSet] = pos
        end

	#matrices are ready
				
	Zp = OrderedDict{Any,Any}()
       	zpz = OrderedDict{Any,Any}() #Has the order in priorVCV, which may be unordered Dict() by the user. Analysis follow this order.
	rhsZ = OrderedDict{Any,Any}()
					
	for pSet ∈ keys(filter(p -> p.first!=:e, priorVCV)) # excluding :e keys(priorVCV) 
		corEffects = []
		corPositions = []
		#symbol :ID or expression :(1|ID)
		if (isa(pSet,Symbol) || isa(pSet,Expr)) && in(pSet,keys(Z))
			tempzpz = []
			nowZ = Z[pSet]
			for c in eachcol(nowZ)
				push!(tempzpz,c'c)					
				# push!(tempzpz,BLAS.dot(c,c))
			end
			Zp[pSet]  = transpose(Z[pSet])						
			zpz[pSet] = tempzpz
			rhsZ[pSet] = zeros(size(Z[pSet],2))
                        if pSet in keys(summaryStat)
                                summaryStat[pSet].v == Array{Float64,1} ? zpz[pSet] .+= inv.(summaryStat[pSet].v) : zpz[pSet] .+= inv.(diag(summaryStat[pSet].v))
                                summaryStat[pSet].v == Array{Float64,1} ? rhsZ[pSet] .= inv.(summaryStat[pSet].v) .* (summaryStat[pSet].m)  : rhsZ[pSet] .= inv.(diag(summaryStat[pSet].v)) .* (summaryStat[pSet].m)
                        end
		#tuple of symbols (:ID,:Dam)
		elseif (isa(pSet,Tuple{Vararg{Symbol}})) && all((in).(pSet,Ref(keys(Z)))) #if all elements are available # all([pSet .in Ref(keys(Z))])
			correlate = collect(pSet)
			for pSubSet in correlate
				push!(corEffects,pSubSet)
				push!(corPositions,findall(pSubSet.==keys(Z))[])
			end
			if issubset(corEffects,collect(keys(Z)))
				tempZ = hcat.(eachcol.(getindex.(Ref(Z), (pSet)))...)
				for d in corEffects
                       			delete!(Z,d)
					delete!(uKeyPos,d)												
               			end
				uKeyPos[pSet] = corPositions
				Z[pSet]   = tempZ
				zpz[pSet] = MatByMat.(tempZ)
				Zp[pSet]  = transpose.(tempZ)
				tempZ = 0
				if pSet in keys(summaryStat)
					error("Not available to use summary statistics in correlated effects")
                        		#SummaryStat[pSet].v == Array{Float64,1} ? zpz[pSet] += inv.(SummaryStat[pSet].v) : zpz[pSet] += inv.(diag(SummaryStat[pSet].v))
                        		#SummaryStat[pSet].v == Array{Float64,1} ? rhsZ[pSet] = inv.(SummaryStat[pSet].v) .* (SummaryStat[pSet].m)  : rhsZ[pSet] = inv.(diag(SummaryStat[pSet].v)) .* (SummaryStat[pSet].m)
                		end
			end
		end
	end
																
	for pSet in collect(keys(Z))[(!in).(keys(Z),Ref(keys(priorVCV)))]
		printstyled("No prior was provided for $pSet, but it was not included in the data. It will be made uncorrelated with default priors\n"; color = :green)		
		tempzpz = []
		nowZ = Z[pSet]
		for c in eachcol(nowZ)
			push!(tempzpz,c'c)					
		end
		Zp[pSet]  = transpose(Z[pSet])						
		zpz[pSet] = tempzpz
		rhsZ[pSet] = zeros(size(Z[pSet],2))
		if pSet in keys(summaryStat)
                	summaryStat[pSet].v == Array{Float64,1} ? zpz[pSet] .+= inv.(summaryStat[pSet].v) : zpz[pSet] .+= inv.(diag(summaryStat[pSet].v))
                        summaryStat[pSet].v == Array{Float64,1} ? rhsZ[pSet] .= inv.(summaryStat[pSet].v) .* (summaryStat[pSet].m)  : rhsZ[pSet] .= inv.(diag(summaryStat[pSet].v)) .* (summaryStat[pSet].m)
                end
	end
																	
	#pos for individual random effect
	#this part "collect(k) .=> collect(v)" will change for correlated random effects.
	uKeyPos4Print = OrderedDict(vcat([(isa(k,Symbol) || isa(k,Expr)) ? k => v : collect(k) .=> collect(v) for (k,v) in uKeyPos]...))
	
	##get priors per effect
													
	iVarStr = Dict{Any,Array{Float64,2}}() #inverses will be computed
	varU_prior = OrderedDict{Any,Any}()
        for zSet in keys(Z)
                nCol = size(Z[zSet],2)
		#var structures and priors
		if haskey(priorVCV,zSet)	
			if ismissing(priorVCV[zSet].str) || priorVCV[zSet].str=="I" 
				printstyled("prior var-cov structure for $zSet is either empty or \"I\" was given. An identity matrix will be used\n"; color = :green)
				iVarStr[zSet] = Matrix(1.0I,nCol,nCol)
			elseif priorVCV[zSet].str=="A"
				printstyled("prior var-cov structure for $zSet is A. Computed A matrix (from pedigree file) will be used\n"; color = :green)
				iVarStr[zSet] = iA
			elseif priorVCV[zSet].str=="G"
                                printstyled("prior var-cov structure for $zSet is G. Computed G matrix will be used\n"; color = :green)
                                iVarStr[zSet] = iGRel[zSet]
			else 	iVarStr[zSet] = inv(priorVCV[zSet].str)
			end
			varU_prior[zSet] = priorVCV[zSet].v
		else	
			printstyled("prior var-cov for $zSet is empty. An identity matrix will be used with mean=0 and variance=100\n"; color = :green)
			varU_prior[zSet] = 100
			priorVCV[zSet] = Random("I",0,100)
			iVarStr[zSet] = Matrix(1.0I,nCol,nCol)
		end
        end

	#df, shape, scale...															
	
	dfZ = Dict{Any,Any}()	
	for zSet ∈ keys(zpz)
		dfZ[zSet] = 3.0+size(priorVCV[zSet].v,1)
	end
																
	scaleZ = Dict{Any,Any}()
        for zSet in keys(zpz)
                nZComp = size(priorVCV[zSet].v,1)
		#priorVCV[zSet].v is a temporary solution
		nZComp > 1 ? scaleZ[zSet] = priorVCV[zSet].v .* (dfZ[zSet]-nZComp-1.0)  : scaleZ[zSet] = priorVCV[zSet].v * (dfZ[zSet]-2.0)/dfZ[zSet] #I make float and array of float														
        end


												
        ####
																					

	#ADD MARKERS
	# read map file and make regions
																		
	############priorVCV cannot be empty for markers, currently!!																	

	#key positions for each effect in beta, for speed. Order of matrices in M are preserved here.
        for mSet in keys(M)
                pos = findall(mSet.==collect(keys(M)))[]
                M[mSet][:pos] = pos
        end

	beta = []

	#make mpm

	
	regionArray = OrderedDict{Any,Array{UnitRange{Int64},1}}()	
	
	for pSet ∈ keys(filter(p -> p.first!=:e, priorVCV)) # excluding :e keys(priorVCV)
		corEffects = []
		corPositions = []
		#symbol :M1 or expression
		if isa(pSet,Symbol) && in(pSet,keys(M))
			tempmpm = []
			nowM = M[pSet][:data]
			for c in eachcol(nowM)
				push!(tempmpm,BLAS.dot(c,c))
			end
			M[pSet][:mpm] = tempmpm
			M[pSet][:rhs] = zeros(M[pSet][:size][2])
			if pSet in keys(summaryStat)
				summaryStat[pSet].v == Array{Float64,1} ? M[pSet][:mpm] .+= inv.(summaryStat[pSet].v) : M[pSet][:mpm] .+= inv.(diag(summaryStat[pSet].v))
				summaryStat[pSet].v == Array{Float64,1} ? M[pSet][:rhs] .= inv.(summaryStat[pSet].v) .* (summaryStat[pSet].m)  : M[pSet][:rhs] .= inv.(diag(summaryStat[pSet].v)) .* (summaryStat[pSet].m)
                        end
			M[pSet][:Mp] = []
			theseRegions = prep2RegionData(outPut,pSet,M[pSet][:map],priorVCV[pSet].r)
		        M[pSet][:regionArray] = theseRegions
			M[pSet][:nRegions] = length(theseRegions)
			
			beta = zeros(Float64,1,M[pSet][:size][2])

		#tuple of symbols (:M1,:M2)
		elseif (isa(pSet,Tuple{Vararg{Symbol}})) && all((in).(pSet,Ref(keys(M)))) #if all elements are available # all([pSet .in Ref(keys(M))])
			correlate = collect(pSet)
			for pSubSet in correlate
				push!(corEffects,pSubSet)
				push!(corPositions,findall(pSubSet.==keys(M))[])
			end
			if issubset(corEffects,collect(keys(M)))
				tempM = hcat.(eachcol.(getindex.(Ref(M), (pSet)))...)
				for d in corEffects
                       			delete!(M,d)
					delete!(BetaKeyPos,d)
               			end
				BetaKeyPos[pSet] = corPositions
				M[pSet]   = tempM
				mpm[pSet] = MatByMat.(tempM)
				if pSet in SummaryStat
					error("Not available to use summary statistics in correlated effects")
                                	#SummaryStat[pSet].v == Array{Float64,1} ? mpm[pSet] += (1.0 ./ SummaryStat[pSet].v) : mpm[pSet] += inv.(diag(SummaryStat[pSet].v))
 	                       	end
 
				Mp[pSet]  = transpose.(tempM)
				tempM = 0
				nowMap = first(pSet)		#should throw out error if sets have different lengths! implement it here!
				theseRegions = prep2RegionData(outPut,pSet,paths2maps[nowMap],priorVCV[pSet].r)
                		regionArray[pSet] = theseRegions
			end
		end
	end
	
	for pSet in collect(keys(M))[(!in).(keys(M),Ref(keys(priorVCV)))]
		printstyled("No prior was provided for $pSet, but it was included in the data. It will be made uncorrelated with default priors and region size 9999 (WG)\n"; color = :green)		
		tempmpm = []
		nowM = M[pSet][:data]
		for c in eachcol(nowM)
			push!(tempmpm,BLAS.dot(c,c))
		end
		M[pSet][:mpm] = tempmpm
		M[pSet][:rhs] = zeros(M[pSet][:size][2])
                if pSet in keys(summaryStat)
			summaryStat[pSet].v == Array{Float64,1} ? M[pSet][:mpm] .+= inv.(summaryStat[pSet].v) : M[pSet][:mpm] .+= inv.(diag(summaryStat[pSet].v))
                        summaryStat[pSet].v == Array{Float64,1} ? M[pSet][:rhs] .= inv.(summaryStat[pSet].v) .* (summaryStat[pSet].m)  : M[pSet][:rhs] .= inv.(diag(summaryStat[pSet].v)) .* (summaryStat[pSet].m)
                end
		theseRegions = prep2RegionData(outPut,pSet,M[pSet][:map],9999)
		regionArray[pSet] = theseRegions
	end

	
	for mSet ∈ keys(mpm)
		M[mSet][:df] = 3.0+size(priorVCV[mSet].v,1)
	end


        for mSet in keys(M)
                nMComp = size(priorVCV[mSet].v,1)
                nMComp > 1 ? M[mSet][:scale] = priorVCV[mSet].v .* (M[mSet][:df]-nMComp-1.0)  : M[mSet][:scale] = priorVCV[mSet].v * (M[mSet][:df]-2.0)/(M[mSet][:df]) #I make float and array of float
        end
	
	
	#storage
	u = zeros(Float64,nRand,maximum(vcat([0,collect(values(nColEachZ))]...))) #zero is for max to work when no random effect is present #can allow unequal length! Remove tail zeros for printing....

	varU = deepcopy(varU_prior) #for storage

	varBeta = Dict{Symbol,Any}()
        for mSet in keys(M)
                varBeta[mSet] = [priorVCV[mSet].v for i in 1:length(regionArray[mSet])] #later, direct reference to key when varM_prior is a dictionary
        end

	#summarize analysis
	summarize = DataFrame(Effect=Any[],Type=Any[],Str=Any[],df=Any[],scale=Any[])
	
	for zSet in keys(zpz)
		if zSet ∈ keys(priorVCV)
			str = priorVCV[zSet].str
			#value = priorVCV[zSet].v
		else 
			str = "I"
		     	#value = varU_prior[zSet].v
		end
	push!(summarize,[zSet,"Random",str,dfZ[zSet],scaleZ[zSet]])
	end


	###Bayesian Alphabet methods
	BayesX = OrderedDict{Symbol,Any}()

	for mSet in keys(M)
		if mSet ∈ keys(priorVCV)
			priorVCV[mSet].name == "BayesPR" ? BayesX[mSet] = sampleBayesPR! : nothing
			#BayesX[mSet] = typeof(priorVCV[mSet])
			str = "$(nRegions[mSet]) block(s)"
			#value = priorVCV[mSet].v
		else #### later, handel this above, when dealing with priorVCV is allowed to be empty
			BayesX[mSet] = BayesPR #with region size 9999
			str = "WG(I)"
		     	#value = 0.001
		end
	push!(summarize,[mSet,"Random (Marker)",str,M[mSet][:df],M[mSet][:scale]])
	end
	

	push!(summarize,["e","Random",priorVCV[:e].str,dfE,scaleE])						

	println("\n ---------------- Summary of analysis ---------------- \n")
	pretty_table(summarize, tf = tf_markdown, show_row_number = false,nosubheader=true,alignment=:l)


	#########make MCMC output files.
	IO.outMCMC(outPut,"b",levelsX)
	
	#check for correlated RE
        for i in 1:length(levelDict[:levelsRE])
		levRE = hcat(vcat(collect(values(levelDict[:levelsRE]))[i]...)...)
		IO.outMCMC(outPut,"u$i",levRE)
		isa(collect(keys(levelDict[:levelsRE]))[i], Symbol) ? nameRE_VCV = String(collect(keys(levelDict[:levelsRE]))[i]) : nameRE_VCV = join(collect(keys(levelDict[:levelsRE]))[i].args)[2:end]
		IO.outMCMC(outPut,"varU$i",[nameRE_VCV]) #[] to have it as one row
	end	
		
	#arbitrary marker names
	for mSet in keys(M)
   		IO.outMCMC(outPut,"beta$mSet",hcat(M[mSet][:levels]...))
        end
	
	for mSet in keys(varBeta)
		isa(mSet, Symbol) ? nameM_VCV = ["reg_$r" for r in 1:M[mSet][:nRegions]] : nameM_VCV = vcat([["reg_$(i)_$j" for j in 1:size(M[mSet][:scale],2)^2] for i in 1:M[mSet][:nRegions]]...)
		IO.outMCMC(outPut,"var$mSet",[nameM_VCV]) #[] to have it as one row
        end
	

	IO.outMCMC(outPut,"varE",["e"])
	##########
	
	for i in keys(M)
		println("key $i in M: keys(M[i])")
	end
	M  = NamedTuple(M)	
	println("typeof new M: $(typeof(M))")
	
	return ycorr, nData, dfE, scaleE, X, iXpX, XKeyPos, b, Z, iVarStr, Zp, zpz, uKeyPos, uKeyPos4Print, nColEachZ, u, varU, scaleZ, dfZ, M, Mp, mpm, BetaKeyPos, BetaKeyPos4Print, beta, regionArray, nRegions, varBeta, scaleM, dfM, BayesX, rhsX, rhsZ, rhsM
	
end

end