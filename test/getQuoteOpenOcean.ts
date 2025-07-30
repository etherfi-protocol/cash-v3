import axios from "axios";
import { ethers } from "ethers";
import dotenv from "dotenv";
dotenv.config();

function chainIdToChainName(chainId:string) : string {
  if (chainId === "534352") return "scroll";
  else if (chainId === "42161") return "arbitrum";
  else throw new Error("Chain ID unidentified");
}

const OPEN_OCEAN_API_ENDPOINT = `https://open-api-pro.openocean.finance/v4`;
const apikey = process.env.OPENOCEAN_API_KEY;

if (!apikey) throw new Error("OPENOCEAN_API_KEY not found in the .env");

export const getData = async () => {
  const args = process.argv;
  const chainId = args[2];
  const fromAddress = args[3];
  const toAddress = args[4];
  const fromAsset = args[5];
  const toAsset = args[6];
  const fromAmount = args[7]; 
  const fromAssetDecimals = args[8];

  const data = await getOpenOceanSwapData({
    chainId,
    fromAddress,
    toAddress,
    fromAsset,
    toAsset,
    fromAmount,
    fromAssetDecimals
  });
  console.log(data)
};
const getOpenOceanSwapData = async ({
  chainId,
  fromAddress,
  toAddress,
  fromAsset,
  toAsset,
  fromAmount,
  fromAssetDecimals
}: {
  chainId: string;
  fromAddress: string;
  toAddress: string;
  fromAsset: string;
  toAsset: string;
  fromAmount: string;
  fromAssetDecimals: string;
}) => {
  const params = {
    inTokenAddress: fromAsset,
    outTokenAddress: toAsset,
    amount: ethers.utils.formatUnits(fromAmount.toString(), fromAssetDecimals.toString()).toString(),
    sender: fromAddress,
    account: toAddress,
    slippage: 1,
    gasPrice: 0.05,
  };

  let retries = 5;

  const API_ENDPOINT = `${OPEN_OCEAN_API_ENDPOINT}/${chainIdToChainName(chainId)}/swap`;

  while (retries > 0) {
    try {
      const response = await axios.get(API_ENDPOINT, {
        params,
        headers: {
          apikey,
        }
      });

      if (!response.data.data || !response.data.data.data) {
        console.error(response.data);
        throw Error("response is missing data.data");
      }   
      
      return response.data.data.data;
    } catch (err: any) {
      if (err.response) {
        console.error("Response data  : ", err.response.data);
        console.error("Response status: ", err.response.status);
      }
      if (err.response?.status == 429) {
        retries = retries - 1;
        // Wait for 2s before next try
        await new Promise((r) => setTimeout(r, 2000));
        continue;
      }
      throw Error(`Call to OpenOcean swap API failed: ${err.message}`);
    }
  }

  throw Error(`Call to OpenOcean swap API failed: Rate-limited`);
};

getData();