module IO

export outMCMC
export summaryMCMC

using DelimitedFiles
using CSV
using StatsBase
using MCMCChains
using StatsPlots

macro name(arg)
    x = string(arg)
    quote
        $x
    end
end

function outMCMC(folder::String,thisVar,output)
        out0 = open(folder*"/$(thisVar)Out", "a")
        writedlm(out0, output)
        close(out0)
end

function summaryMCMC(param;summary=false,plots=false,outFolder=pwd()*"/outMCMC")
        param = CSV.read("$outFolder/$(param)Out",DataFrame,header=true)
	namesParam = names(param)
	param = Matrix(param)
                if summary==true
                        chn = Chains(param,namesParam)
                        display(chn)
			if plots=true
                       		display(plot(chn))
			end
                        param = mean(Matrix(param),dims=1)
                else 
			param = mean(Matrix(param),dims=1)
                end
        return param
end

end
