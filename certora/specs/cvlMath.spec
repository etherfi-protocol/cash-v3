/******************************************
----------- CVL Math Library --------------
*******************************************/

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => cvlMulDiv(x, y, denominator);
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => cvlMulDivDirectional(x, y, denominator, rounding);
}

function cvlMulDiv(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    require denominator != 0;
    return require_uint256(x*y/denominator);
}

function cvlMulDivUp(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    require denominator != 0;
    return require_uint256((x*y + denominator - 1)/denominator);
}

function cvlMulDivDirectional(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    if (rounding == Math.Rounding.Ceil) {
        return cvlMulDivUp(x, y, denominator);
    } else {
        return cvlMulDiv(x, y, denominator);
    }
}

function cvlMulDivDown(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    require (denominator != 0);
    return require_uint256(x * y / denominator);
}        

function mulDivDownAbstract(uint256 x, uint256 y, uint256 z) returns uint256 {
    require z !=0;
    uint256 xy = require_uint256(x * y);
    uint256 res;
    mathint rem; 
    require z * res + rem == to_mathint(xy);
    require rem < to_mathint(z);
    return res; 
}

function mulDivDownAbstractPlus(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    require z != 0;
    uint256 xy = require_uint256(x * y);
    uint256 fz = require_uint256(res * z);

    require xy >= fz;
    require fz + z > to_mathint(xy);
    return res; 
}

function mulDivUpAbstractPlus(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    require z != 0;
    uint256 xy = require_uint256(x * y);
    uint256 fz = require_uint256(res * z);
    require xy >= fz;
    require fz + z > to_mathint(xy);
    
    if(xy == fz) {
        return res;
    } 
    return require_uint256(res + 1);
}
