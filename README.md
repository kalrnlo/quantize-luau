quantize-luau
========

Luau module for color quantization, based on [quantize.js](https://github.com/olivierlesnicki/quantize) and [Leptonica](https://github.com/DanBloomberg/leptonica/blob/master/src/colorquant2.c).


Quick Overview
--------------

### Usage

`````lua
local Quantize = require(Path.To.Quantize)

local ArrayOfPixels = {{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}}
local MaximumColorCount = 4

local ColorMap = Quantize(ArrayOfPixels, MaximumColorCount)
`````

* `Pixels` - An array of pixels (represented as {R,G,B arrays}) or Color3s to quantize
* `MaxiumColorCount` - The maximum number of colours allowed in the reduced palette

##### Reduced Palette

The `:Palette()` method returns an array that contains the reduced color palette.

`````lua
-- Returns the reduced palette
ColorMap:Palette()
-- {{204, 204, 204}, {208,212,212}, {188,196,188}, {212,204,196}}
`````

##### Reduced pixel

The `:Map(Pixel)` method maps an individual pixel to the reduced color palette.

`````lua
-- Returns the reduced pixel
ColorMap:Map(ArrayOfPixels[1])
-- {188,196,188}
`````
