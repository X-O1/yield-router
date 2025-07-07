// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract IncentivizedAutomation {
    // Incentivized Automation
    // if router is called by anyone other than owner then calling address earns small amount of value routed
    // incentivaizes routing automation without off-chain dependecies
    // router owner can choose to turn off incentivized automation will be on by default;
    /* 
    | Routed Yield (USD) | Fee Type             
    | ------------------ | ---------------------- | 
    | \$0 – \$99.99      | Flat \$0.10            | 
    | \$100 – \$499.99   | 0.075% of routed amount | 
    | \$500 – \$999.99   | 0.05%                 | 
    | \$1000 – \$4999.99 | 0.035%                  | 
    | \$5000+            | 0.01%                  | 
    */
}
