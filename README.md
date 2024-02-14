quantize-luau
========

A fully typed Luau module for MMCQ color quantization. With added support for Color3s to be used instead of RGB arrays. Based on [quantize.js](https://github.com/olivierlesnicki/quantize) and [Leptonica](https://github.com/DanBloomberg/leptonica/blob/master/src/colorquant2.c).


Example
--------------

`````lua
local Quantize = require(Path.To.Quantize)

local ArrayOfPixels = {{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}}
local MaxColors = 4

local ColorMap = Quantize.General(ArrayOfPixels, MaxColors)
local Palette = ColorMap:Palette()
`````

API
--------------
### Quantization

#### Simple
`````lua
-- Wrapper around Quantize.General() for easier usage. 
-- This method sets MaxColors to 256, and AllowGreyscale to false.
local ColorMap = Quantize.Simple(ArrayOfPixels)
`````
* `Pixels` - An array of pixels (represented as {R,G,B arrays}) or Color3s to quantize

#### General
`````lua
local Options = {
	AllowGreyscale = true,
	OutputSize = 8,
}

local ColorMap = Quantize.General(ArrayOfPixels, MaxColors, Options)
`````
* `Pixels` - An array of pixels (represented as {R,G,B arrays}) or Color3s to quantize
* `MaxColors` - The maximum number of colors allowed in the reduced palette, must be within 2 to 256
  
* `Options`
	* *`AllowGreyscale`* - Whether or not Quantize should check if color content is very small. Or force greyscale onto the palette if the first color is very bright and the last is very dark.
	* *`OutputSize`* - The size of the returned palette, can be either 1, 2, 4 or 8 and cannot exceed 2 ^ OutputSize. 

#### Mixed
`````lua
-- Note: GreyAmount + ColorsPerSignificantPixel cannot exceed 255
local ColorsPerSignificantPixel = 8
local GreyAmount = 10
local Options = {
	LightThreshold = 20,
	DarkThreshold = 244,
	DiffThreshold = 20,
}

local ColorMap = Quantize.Mixed(ArrayOfPixels, ColorsPerSignificantPixel, GreyAmount, Options)
`````
* `Pixels` - An array of pixels (represented as {R,G,B arrays}) or Color3s to quantize
* `ColorsPerSignificantPixel` - The amount of colors to be assigned to pixels with significant color
* `GreyAmount` - Amount of gray colors to be used, must be greater than or equal to 2
  
* `Options`
	* *`LightThreshold`* - Threshold towards white; if the darkest RGB component of a pixel is above this, the pixel is not considered to be gray or color
	* *`DarkThreshold`* - Threshold towards black; if the lightest RGB component of a pixel is below this, the pixel is not considered to be gray or color
	* *`DiffThreshold`* - Threshhold for the max difference between RGB component values, for differences below this the pixel is considered to be gray
 

#### Mixed Few Colors
`````lua
-- Note: Both ColorsPerSignificantPixel and GreyAmount if set should be at least equal to MaxColors,
-- if they aren't a warning is given.
local Options = {
	ColorsPerSignificantPixel = 20,
	LightThreshold = 244,
	DiffThreshold = 15,
	DarkThreshold = 20,
	GreyAmount = 20,
	MaxColors = 20,
}

local ColorMap = Quantize.MixedFewColors(ArrayOfPixels, Options)
`````
* `Pixels` - An array of pixels (represented as {R,G,B arrays}) or Color3s to quantize
* `MaxColors` - The maximum number of colors allowed in the reduced palette, must be within 2 to 256
  
* `Options`
	* *`DarkThreshold`* -  Threshold towards black; if the lightest RGB component of a pixel is below this, the pixel is not considered to be gray or color
	* *`LightThreshold`* - Threshold towards white; if the darkest RGB component of a pixel is above this, the pixel is not considered to be gray or color
	* *`DiffThreshold`* - Threshhold for the max difference between RGB component values, for differences below this the pixel is considered to be gray
	* *`MaxColors`* - The maximum number of colors allowed in the reduced palette, must be within 2 to 256
	* *`ColorsPerSignificantPixel`* - The amount of colors to be assigned to pixels with significant color 
	* *`GreyAmount`* - Amount of gray colors to be used, must be greater than or equal to 2
---

### Color Map

#### Reduced Palette

The `:Palette()` method returns an array that contains the reduced color palette.

`````lua
-- Returns the reduced palette
ColorMap:Palette()
-- {{204, 204, 204}, {208,212,212}, {188,196,188}, {212,204,196}}
`````

#### Reduced Color

The `:Map(Pixel)` method maps an individual pixel or Color3 to the reduced color palette.

`````lua
-- Returns the reduced pixel
ColorMap:Map(ArrayOfPixels[1])
-- {188,196,188}
`````
