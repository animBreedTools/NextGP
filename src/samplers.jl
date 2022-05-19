module samplers

using Distributions, LinearAlgebra

export runSampler

#main sampler
runSampler = function(Y,X,Z,varE) ##varE will be fixed for now
        nFix = length(X)

        #initial computations and settings
        #make iXpX
        iXpX = similar(X)
        for x in 1:nFix
                iXpX[x] = inv(X[x]'X[x])
        end
        #make b array
        b = Array{Array{Float64, 1},1}(undef,0)
        #counts columns per effect
        nColEachX = []
        for x in 1:nFix
                println(x)
                nCol = size(X[x],2)
                push!(b,fill(0.0,nCol))
                nColEachX = push!(nColEachX,nCol)
        end

        #sample fixed effects
        #always returns corrected Y and new b
        sampleX!(X,b,iXpX,nFix,nColEachX,Y,varE)

        #print
        println("sampled b: $b")
end


#Sampling fixed effects
sampleX! = function(X,b,iXpX,nFix,nColEachX,ycorr,varE)
	#block for each effect 
	for x in 1:nFix
                println("sampling $x")
		ycorr    .+= X[x]*b[x]
                println("ycorr $ycorr")
        	rhs      = X[x]'*ycorr
                println("rhs $rhs")
        	iLhs   = iXpX[x]
                println("iLhs $iLhs")
        	meanMu   = iLhs*rhs
                println("meanMu $meanMu")
		if nColEachX[x] == 1
        		b[x] .= rand(Normal(meanMu[],(iLhs*varE)[]))
		else b[x] .= rand(MvNormal(meanMu,convert(Array,Symmetric(iLhs*varE))))
		end
        	ycorr    .-= X[x]*b[x]
	end
end

end
