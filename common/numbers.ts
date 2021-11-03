import { BigNumberish, BigNumber } from 'ethers'
import { ethers } from 'hardhat'
import { BN_SCALE_FACTOR, SCALE_DECIMALS } from './constants'

export const ZERO = BigNumber.from(0)

// Convenience form for "BigNumber.from" that also accepts scientific notation
export const bn = (x: BigNumberish): BigNumber => {
  if (typeof x === 'string') return _parseScientific(x)
  return BigNumber.from(x)
}

export const pow10 = (exponent: BigNumberish): BigNumber => {
  return BigNumber.from(10).pow(exponent)
}

// Convert to Fix (or scaled-int) from a string or BigNumber representation.
//   If the arg is a string, it can have a decimal point and/or scientific-notation exponent.
export const fp = (x: string | BigNumberish): BigNumber => {
  if (typeof x === 'string') return _parseScientific(x, SCALE_DECIMALS)
  return BigNumber.from(x).mul(pow10(SCALE_DECIMALS))
}

export const divCeil = (x: BigNumber, y: BigNumber): BigNumber =>
  // ceil(x/y) == (x + y - 1) / y
  x.add(y).sub(1).div(y)

// _parseScientific(s, scale) returns a BigNumber with value (s * 10**scale),
// where s is a string in decimal or scientific notation,
// and scale is a BigNumberish indicating a number of additional zeroes to add to the right,
// Fractional digits in the result are truncated.
// TODO: Maybe we should error if we're truncating digits instead?
//
// A few examples:
//     _parseScientific('1.4e2') == BigNumber.from(140)
//     _parseScientific('-2') == BigNumber.from(-2)
//     _parseScientific('0.5', 18) == BigNumber.from(5).mul(pow10(17))
//     _parseScientific('0.127e2') == BigNumber.from(12)
function _parseScientific(s: string, scale: BigNumberish = 0): BigNumber {
  // Scientific Notation: <INT>(.<DIGITS>)?(e<INT>)?
  // INT: [+-]?DIGITS
  // DIGITS: \d+
  const match = s.match(/^(?<int_part>[+-]?\d+)(\.(?<frac_part>\d+))?(e(?<exponent>[+-]?\d+))?$/)
  if (!match || !match.groups) throw new Error(`Illegal decimal string ${s}`)

  let int_part = BigNumber.from(match.groups.int_part)
  const frac_part = match.groups.frac_part ? BigNumber.from(match.groups.frac_part) : ZERO
  let exponent = match.groups.exponent ? BigNumber.from(match.groups.exponent) : ZERO
  exponent = exponent.add(scale)

  // If this is negative, do our work in the positive domain, but remember the negation.
  const is_negative = int_part.lt(0)
  int_part = int_part.abs()

  // "zero" the fractional part by shifting it into int_part, keeping the overall value equal
  if (!frac_part.eq(ZERO)) {
    const shift_digits = match.groups.frac_part.length
    int_part = int_part.mul(pow10(shift_digits)).add(frac_part)
    exponent = exponent.sub(shift_digits)
  }

  // Shift int_part left or right as exponent requires
  const positive_output: BigNumber = exponent.gte(ZERO)
    ? int_part.mul(pow10(exponent))
    : int_part.div(pow10(exponent.abs()))

  return is_negative ? positive_output.mul(-1) : positive_output
}
