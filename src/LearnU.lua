


local function trainNN(train, test, config, name)

   -- retrieve layer size
   local bottleneck = {}
   bottleneck[0] = train.dimension
   
   local i = 0
   for key, confLayer in pairs(config) do
         if string.starts(key, "layer") then
            i = i + 1
            bottleneck[i] = math.floor(train.dimension / confLayer.coefLayer)
         end
   end



   --Step 1 : Build networks
   local encoders = {}
   local decoders = {}
   local finalNetwork
   
   local i = 0
   
   for key, confLayer in pairs(config) do
   
      if string.starts(key, "layer") then
         i = i + 1
      
         --ENCODERS
         encoders[i] = nn.Sequential()
         
         --TODO testU Densify vs SparseLinear
         
         if i == 1  then 
            if USE_GPU then
               encoders[i]:add(nnsparse.Densify(bottleneck[i-1])) 
               encoders[i]:add(nn.Linear(bottleneck[i-1], bottleneck[i]))
            else
               encoders[i]:add(nnsparse.SparseLinearBatch(bottleneck[i-1], bottleneck[i], false))
            end               
         else
            encoders[i]:add(nn.Linear(bottleneck[i-1], bottleneck[i]))
         end
                  
         encoders[i]:add(nn.Tanh())
         
         --DECODERS
         decoders[i] = nn.Sequential()
         decoders[i]:add(nn.Linear(bottleneck[i],bottleneck[i-1]))
         decoders[i]:add(nn.Tanh())
         
         -- tied weights
         if confLayer.isTied == true then
            decoders[i]:get(1).weight     = encoders[i]:get(1).weight:t()
            decoders[i]:get(1).gradWeight = encoders[i]:get(1).gradWeight:t()
         end
            
      end
   
   end
   


   local error = {rmse = {}, mae = {}}
   

   --Step 2 : train networks  - Stacked Autoencoder algorithm
   local noLayer = 0
   for key, confLayer in pairs(config) do

      if string.starts(key, "layer") then

         noLayer = noLayer + 1
         for k = noLayer, 1, -1 do 

            --Retrieve configuration      
            local step    = noLayer-k+1
            local sgdConf = confLayer[step]
            sgdConf.name = name .. "." .. key .. "-" .. step 


            -- Build intermediate networks
            local network = nn.Sequential()
            for i = k      , noLayer,  1 do network:add(encoders[i]) end 
            for i = noLayer, k      , -1 do network:add(decoders[i]) end

            if USE_GPU then 
                 print("use GPU")
                 network:cuda()
                 sgdConf.criterion:cuda()
            end

            network = FlatNetwork(network)


            -- inform the trainer that data are sparse
            if k == 1 then network.isSparse = true end


            --compute data (can be improved)
            local newtrain = train.data
            local newtest  = test.data
            for i = 1, k-1 do
               local batchifier = nnsparse.Batchifier(encoders[i], bottleneck[i])
               newtrain = batchifier:forward(newtrain, 20)
               newtest  = batchifier:forward(newtest, 20) 
            end

            --Train network
            print("Start training : " .. sgdConf.name)
            print(network)

            
            local trainer = AutoEncoderTrainer:new(network, sgdConf, newtrain, newtest, train.info, train.size)
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
   
   --Look for the best RMSE/MAE
   local bestRMSE, bestMAE = 999,999
   for noNetwork = 1, #error.rmse do
      bestRMSE = math.min(bestRMSE, math.min(unpack(error.rmse[noNetwork])))
      bestMAE  = math.min(bestMAE , math.min(unpack(error.mae [noNetwork])))
   end
   
   print("******** BEST RMSE = " .. bestRMSE)
   print("******** BEST MAE  = " .. bestMAE)

   

   local estimate = finalNetwork:forward(train.data)

   return error,estimate

end





function trainU(train, test, config)
   return trainNN(train["U"], test["U"], config, "U")
end

function trainV(train, test, config)

   return trainNN(train["V"], test["V"], config, "V")
end
