function TrainNetwork(train, test, info, config)

   -- retrieve layer size
   local metaDim = 0
   if config.use_meta then -- Metadate, We had it set to false
      metaDim = info.metaDim or 0
   end

   -- Here we gather the configuration pertaining to the dataset we're interested in training on
   local bottleneck = {}
   bottleneck[0] = info.dimension
   local i = 1
   for key, confLayer in pairs(config) do
         if string.starts(key, "layer") then
            bottleneck[i] = confLayer.layerSize
            i = i + 1
         end
   end


   --Step 1 : Build networks
   local encoders = {}
   local decoders = {}
   local finalNetwork
   
    local appenderIn = nil
    if config.use_meta then
        appenderIn = cfn.AppenderIn:new()
    end
   
   
   local i = 0
   for key, confLayer in pairs(config) do
   
      if string.starts(key, "layer") then
         i = i + 1
      
         --ENCODERS
         encoders[i] = nn.Sequential()
         
         if i == 1  then --sparse input
         
            if appenderIn then
               encoders[i]:add(cfn.AppenderSparseOut(appenderIn)) 
            end
            
            if config.use_gpu then
               encoders[i]:add(nnsparse.Densify(bottleneck[i-1] + metaDim)) 
               encoders[i]:add(      nn.Linear (bottleneck[i-1] + metaDim, bottleneck[i]))
            else
               encoders[i]:add(nnsparse.SparseLinearBatch(bottleneck[i-1] + metaDim, bottleneck[i], false))
            end     
                      
         else --dense input, don't pad it
         
            if appenderIn then 
               encoders[i]:add(cfn.AppenderOut(appenderIn)) 
            end
            
            encoders[i]:add(nn.Linear(bottleneck[i-1] + metaDim, bottleneck[i]))
         end
                  
         encoders[i]:add(nn.Tanh())
         
         --DECODERS
         decoders[i] = nn.Sequential()
         
         if appenderIn then 
            decoders[i]:add(cfn.AppenderOut(appenderIn)) 
         end
         
         decoders[i]:add(nn.Linear(bottleneck[i] + metaDim ,bottleneck[i-1]))
         decoders[i]:add(nn.Tanh())
         
         -- tied weights
         if confLayer.isTied == true then
            decoders[i]:get(1).weight     = encoders[i]:get(1).weight:t()
            decoders[i]:get(1).gradWeight = encoders[i]:get(1).gradWeight:t()
         end
            
      end

   end
   -- rmse = root mean squared error
   -- mae = mean absolute error
   local error = {rmse = {}, mae = {}}
   

   --Step 2 : train networks  - Stacked Autoencoders
   local noLayer = 0
   for key, confLayer in pairs(config) do

      if string.starts(key, "layer") then

         noLayer = noLayer + 1 -- wcc (with current config): 1 
         -- noLayer gets incremented by one for each layer in config file
         -- we iterate by -1 from the number of layer at each step 'till 1
         for k = noLayer, 1, -1 do --wcc no iteration

            --Retrieve configuration      
            local step    = noLayer-k+1 -- current step in loop wcc: 1
            local sgdConf = confLayer[step] -- the configuration of the layer wcc: layer1 in conf file
            sgdConf.name = key .. "-" .. step -- layer1-1
            

            --if no epoch, skip!
            if sgdConf.noEpoch > 0 then --wcc = 50 

            	-- Build intermediate networks
            	local network = nn.Sequential()
            	for i = k      , noLayer,  1 do network:add(encoders[i]) end 
            	for i = noLayer, k      , -1 do network:add(decoders[i]) end

            	--Flatten network --> speedup + easier to debug
            	network = cfn.FlatNetwork(network)

            	if config.use_gpu then
            	   network:cuda()
            	   sgdConf.criterion:cuda()
            	end


            	-- inform the trainer that data are sparse
            	if k == 1 then network.isSparse = true end


            	-- provide input information to SDAE (ugly...) and far-fetched
            	if torch.type(sgdConf.criterion) == "cfn.SDAECriterionGPU" then
            	   sgdConf.criterion.inputDim = bottleneck[k-1] -- this is the input coming in from the previous layer, it is the dimension
            	end
            	
            	
            	-- provide side information
            	sgdConf.appenderIn = appenderIn


            	--compute data for intermediate steps (can be improved)
            	local newtrain = train
            	local newtest  = test
            	for i = 1, k-1 do
            	
            	   local batchifier = cfn.Batchifier(encoders[i], bottleneck[i], appenderIn, info)
            	    
            	   newtrain = batchifier:forward(newtrain, 20)
            	   newtest  = batchifier:forward(newtest, 20)
            	end

            	--Train network
            	print("Start training : " .. sgdConf.name)
            	print(network)

            	
            	local trainer = AutoEncoderTrainer.new(network, sgdConf, newtrain, newtest, info)
            	trainer:Execute(sgdConf)

            	-- store loss
            	if k == 1 then 
            	    error.rmse[#error.rmse+1] = trainer.rmse
            	    error.mae [#error.mae +1] = trainer.mae
            	end
            	
            	finalNetwork = network
            	end
         end
      end

   end
   
   --Look for the best RMSE/MAE
   local bestRMSE, bestMAE = 999,999
   for noNetwork = 1, #error.rmse do
      bestRMSE = math.min(bestRMSE, math.min(unpack(error.rmse[noNetwork])))
      bestMAE  = math.min(bestMAE , math.min(unpack(error.mae [noNetwork])))
   end
   
   print("******** BEST RMSE = " .. bestRMSE)
   print("******** BEST MAE  = " .. bestMAE)


   return bestRMSE, finalNetwork

end

