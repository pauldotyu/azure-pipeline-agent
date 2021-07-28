# setup variables
rg_name="rg-ohdemo"
rg_location="westus2"
kv_name="kv-ohdemo"
mi_name="mi-ohdemo"
vnet_name="vn-ohdemo"
vnet_addr="10.0.0.0/16"
nsg_name="nsg-ohdemo"
snet_name="sn-ohdemo"
snet_addr="10.0.0.0/24"
acr_name="acrohdemo0728"
azdo_url="https://dev.azure.com/pauyu/"
azdo_pool="ohdemo1"
aci_name="aciohdemo0728b"

# create resource group
az group create -n $rg_name -l $rg_location

# create key vault
az keyvault create -g $rg_name -l $rg_location -n $kv_name

# create managed identity
az identity create -g $rg_name -l $rg_location -n $mi_name

# create virtual network
az network vnet create -g $rg_name -l $rg_location -n $vnet_name --address-prefixes $vnet_addr

# create network security group
az network nsg create -g $rg_name -n $nsg_name

# create subnet
snet_id=$(az network vnet subnet create -g $rg_name --vnet-name $vnet_name -n $snet_name --nsg $nsg_name --address-prefixes $snet_addr --query "id" -o tsv)

# delegate the subnet
az network vnet subnet update \
  --resource-group $rg_name \
  --name $snet_name \
  --vnet-name $vnet_name \
  --delegations Microsoft.ContainerInstance/containerGroups

# create azure container registry
az acr create -g $rg_name -n $acr_name --sku Standard

# build the container
docker build -t ohdemo:latest .

# run the agent locally
docker run -d -e AZP_URL=$azdo_url -e AZP_TOKEN=$(az keyvault secret show --vault-name $kv_name -n pat-ohdemo --query value -o tsv) -e AZP_AGENT_NAME=$(hostname)-1 -e AZP_POOL=$azdo_pool ohdemo:latest

# push the container to acr
az acr login -n $acr_name
acr_login_server=$(az acr show --name $acr_name --resource-group $rg_name --query "loginServer" --output tsv)

docker tag ohdemo $acr_login_server/ohdemo:latest
docker push $acr_login_server/ohdemo:latest


az acr build --registry $acr_name --image $acr_login_server/ohdemo:v1 .

# create a service principal, give it acrpull on your acr, and store password in key vault
az keyvault secret set \
  --vault-name $kv_name \
  --name $acr_name-pull-pwd \
  --value $(az ad sp create-for-rbac \
        --name http://$acr_name-pull \
        --scopes $(az acr show --name $acr_name --query id --output tsv) \
        --role acrpull \
        --query password \
        --output tsv)

az keyvault secret set \
  --vault-name $kv_name \
  --name $acr_name-pull-usr \
  --value $(az ad sp show --id http://$acr_name-pull --query appId --output tsv)

# create the aci
az container create \
  -g $rg_name \
  -n $aci_name \
  --image $acr_login_server/ohdemo:v1 \
  --registry-login-server $acr_login_server \
  --registry-username $(az keyvault secret show --vault-name $kv_name -n $acr_name-pull-usr --query value -o tsv) \
  --registry-password $(az keyvault secret show --vault-name $kv_name -n $acr_name-pull-pwd --query value -o tsv) \
  --assign-identity $(az identity show -n $mi_name -g $rg_name --query id -o tsv) \
  --ip-address Private \
  --vnet $vnet_name \
  --subnet $snet_name \
  --restart-policy never \
  --cpu 1 \
  --memory 1 \
  --os-type Linux \
  -e AZP_URL=$azdo_url AZP_AGENT_NAME=$aci_name AZP_POOL=$azdo_pool \
  --secure-environment-variables AZP_TOKEN=$(az keyvault secret show --vault-name $kv_name -n pat-ohdemo --query value -o tsv)