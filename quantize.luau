--!optimize 2
--!strict

-- Quantize.luau
-- A fully typed Luau module for MMCQ color quantization. 
-- With added support for Color3s to be used instead of RGB arrays. 
-- Based on quantize.js and Leptonica.
-- @Kalrnlo
-- 09/02/2024

-- TODO:
-- Remove greyscale method, and implement it into the quantize function
-- like leptronica https://github.com/DanBloomberg/leptonica/blob/e09c1f283aa5a896facc297b617775373519d450/src/colorquant2.c#L533
-- Remove VolumeBox class and use structs instead for VolumeBox data
-- Add in Mixed & MixedFewColor quantize methods from leptronica (possibly)

type Comparator = (A: VolumeBox, B: VolumeBox) -> boolean

type BaseColorData = {
	Pixel: Pixel
}

-- Replacement for volume boxes so stuff like map will still work possibly?
type VolumeColorData = {
	RedMin: number,
	RedMax: number,
	GreenMin: number,
	GreenMax: number,
	BlueMin: number,
	BlueMax: number,
	Pixel: Pixel,
}

type ColorData = BaseColorData | VolumeColorData

type PriorityQueue = {
	VolumeBoxes: {VolumeBox},
	__sorted: boolean
}

type GeneralQuantizeOptions = {
	CheckGreyscale: boolean?,
	Outdepth: number?,
	Height: number?,
	Width: number?,
}

type MixedQuantizeOptions = {
	LightThreshold: number?,
	DiffThreshold: number?,
	DarkThreshold: number?,
	Height: number?,
	Width: number?,
}

type ColorMapPrototype = {
	Nearest: ((self: ColorMap, Pixel: Pixel) -> Pixel) 
		& ((self: ColorMap, Color3: Color3) -> Pixel?),
	Map: ((self: ColorMap, Pixel: Pixel) -> Pixel) 
		& ((self: ColorMap, Color3: Color3) -> Pixel?),
	Palette: (self: ColorMap) -> {Pixel},

	__len: (self: ColorMap) -> number,
	__index: ColorMapPrototype,
}

type VolumeBoxPrototype = {
	Volume: (self: VolumeBox, Force: boolean?) -> number,
	Average: (self: VolumeBox, Force: boolean?) -> Pixel,
	Count: (self: VolumeBox, Force: boolean?) -> number,
	Copy: (self: VolumeBox) -> VolumeBox,

	__len: (self: VolumeBox) -> number,
	__index: VolumeBoxPrototype,
}

export type VolumeBox = typeof(setmetatable({} :: {
	Histo: {number},
	RedMin: number,
	RedMax: number,
	GreenMin: number,
	GreenMax: number,
	BlueMin: number,
	BlueMax: number,

	__average_pixel: Pixel?,
	__volume: number?,
	__count: number?,
}, {} :: VolumeBoxPrototype))

export type ColorMap = typeof(setmetatable({} :: {
	Colors: {BaseColorData | VolumeColorData}
}, {} :: ColorMapPrototype))

--[[
    Commented out as luau doesnt type this correctly rn
    export type Pixel = {number} | {
	    ["1"]: number,
	    ["2"]: number,
	    ["3"]: number,
    }
--]]

export type Pixel = {number}

local InvalidPixelAtIndexFormat = "[Quantize] %s value in Pixel at index &d, is not in range 0..255"
local ConversionHex = 0xFFFFFFFF
local FractByPopulations = 0.75	
local MaxIterations = 1000
local Sigbits = 5
local Shift = 8 - Sigbits
local HistoSize = bit32.lshift(1, 3 * Sigbits)
local VboxAvgMult = bit32.lshift(1, Shift)
local PaletteSize16 = bit32.lshift(1, 4)
local PaletteSize2 = bit32.lshift(1, 1)
local PaletteSize4 = bit32.lshift(1, 2)
local PaletteSize0 = bit32.lshift(1, 8)
local Mask = bit32.rshift(0xff, Shift)

--[[
/* ----------------------------------------------------------------------- *
 *   Find the fraction of pixels with "color" that are not close to black  *
 * ----------------------------------------------------------------------- */
/*!
 * \brief   pixColorFraction()
 *
 * \param[in]    pixs  32 bpp rgb
 * \param[in]    darkthresh    threshold near black; if the largest (lightest)
 *                             component is below this, the pixel is not
 *                             considered in the statistics; typ. 20
 * \param[in]    lightthresh   threshold near white; if the smallest (darkest)
 *                             component is above this, the pixel is not
 *                             considered in the statistics; typ. 244
 * \param[in]    diffthresh    thresh for the maximum difference between
 *                             component values; below this the pixel is not
 *                             considered to have sufficient color
 * \param[out]   ppixfract     [optional] fraction of pixels in intermediate
 *                             brightness range that were considered
 *                             for color content
 * \param[out]   pcolorfract   [optional] fraction of pixels that meet the
 *                             criterion for sufficient color; 0.0 on error
 * \return  0 if OK, 1 on error
 *
 * <pre>
 * Notes:
 *      (1) This function is asking the question: to what extent does the
 *          image appear to have color?   The amount of color a pixel
 *          appears to have depends on both the deviation of the
 *          individual components from their average and on the average
 *          intensity itself.  For example, the color will be much more
 *          obvious with a small deviation from white than the same
 *          deviation from black.
 *      (2) Any pixel that meets these three tests is considered a
 *          colorful pixel:
 *            (a) the lightest component must equal or exceed %darkthresh
 *            (b) the darkest component must not exceed %lightthresh
 *            (c) the max difference between components must equal or
 *                exceed %diffthresh.
 *      (3) The dark pixels are removed from consideration because
 *          they don't appear to have color.
 *      (4) The very lightest pixels are removed because if an image
 *          has a lot of "white", the color fraction will be artificially
 *          low, even if all the other pixels are colorful.
 *      (5) If pixfract is very small, there are few pixels that are neither
 *          black nor white.  If colorfract is very small, the pixels
 *          that are neither black nor white have very little color
 *          content.  The product 'pixfract * colorfract' gives the
 *          fraction of pixels with significant color content.
 *      (6) One use of this function is as a preprocessing step for median
 *          cut quantization (colorquant2.c), which does a very poor job
 *          splitting the color space into rectangular volume elements when
 *          all the pixels are near the diagonal of the color cube.  For
 *          octree quantization of an image with only gray values, the
 *          2^(level) octcubes on the diagonal are the only ones
 *          that can be occupied.
 * </pre>
 */
l_ok
pixColorFraction(PIX        *pixs,
                 l_int32     darkthresh,
                 l_int32     lightthresh,
                 l_int32     diffthresh,
                 l_int32     factor,
                 l_float32  *ppixfract,
                 l_float32  *pcolorfract)
{
l_int32    i, j, w, h, wpl, rval, gval, bval, minval, maxval;
l_int32    total, npix, ncolor;
l_uint32   pixel;
l_uint32  *data, *line;

    if (ppixfract) *ppixfract = 0.0;
    if (pcolorfract) *pcolorfract = 0.0;
    if (!ppixfract && !pcolorfract)
        return ERROR_INT("neither &pixfract nor &colorfract are defined",
                         __func__, 1);
    if (!pixs || pixGetDepth(pixs) != 32)
        return ERROR_INT("pixs not defined or not 32 bpp", __func__, 1);

    pixGetDimensions(pixs, &w, &h, NULL);
    data = pixGetData(pixs);
    wpl = pixGetWpl(pixs);
    npix = ncolor = total = 0;
    for (i = 0; i < h; i += factor) {
        line = data + i * wpl;
        for (j = 0; j < w; j += factor) {
            total++;
            pixel = line[j];
            extractRGBValues(pixel, &rval, &gval, &bval);
            minval = L_MIN(rval, gval);
            minval = L_MIN(minval, bval);
            if (minval > lightthresh)  /* near white */
                continue;
            maxval = L_MAX(rval, gval);
            maxval = L_MAX(maxval, bval);
            if (maxval < darkthresh)  /* near black */
                continue;

            npix++;
            if (maxval - minval >= diffthresh)
                ncolor++;
        }
    }

    if (npix == 0) {
        L_WARNING("No pixels found for consideration\n", __func__);
        return 0;
    }
    if (ppixfract) *ppixfract = (l_float32)npix / (l_float32)total;
    if (pcolorfract) *pcolorfract = (l_float32)ncolor / (l_float32)npix;
    return 0;
}
--]]

-- pixColorFraction(pixs, 20, 244, 20, factor, &pixfract, &colorfract);
local function GetColorFraction(
	Pixels: {Pixel},
	DarkThreshold: number,
	LightThreshold: number,
	DiffThreshold: number
)
	local ColorCount = 0
	local PixelCount = 0

	for Index, Pixel, in Pixels do
		local MinValue = math.min(math.min(Pixel[1], Pixel[2]), Pixel[3])

		-- near white
		if math.min(math.min(Pixel[1], Pixel[2]), Pixel[3]) > LightThreshold then
			continue
		end
		local MaxValue = math.max(math.max(Pixel[1], Pixel[2]), Pixel[3]) 

		-- near black
		if math.max(math.max(Pixel[1], Pixel[2]), Pixel[3]) < DarkThreshold then 
			continue 
		end

		PixelCount += 1
		if MaxValue - MinValue >= DiffThreshold then
			ColorCount += 1
		end
	end
	
	return PixelCount / #Pixels, ColorCount / #Pixels
end

local function GetOrCreatePixel(PixelOrColor3: Pixel | Color3): Pixel
	if typeof(PixelOrColor3) == "table" then
		if Pixel[1] > 255 or Pixel[1] < 0 then
			error("[Quantize] Red value in Pixel is not in range 0..255")
		elseif Pixel[2] > 255 or Pixel[2] < 0 then
			error("[Quantize] Green value in Pixel is not in range 0..255")
		elseif Pixel[3] > 255 or Pixel[3] < 0 then
			error("[Quantize] Blue value in Pixel is not in range 0..255")
		end
		return PixelOrColor3
	else
		local Pixel = table.create(3)
		Pixel[1] = math.clamp(math.ceil(PixelOrColor3.R * 255), 0, 255)
		Pixel[2] = math.clamp(math.ceil(PixelOrColor3.G * 255), 0, 255)
		Pixel[3] = math.clamp(math.ceil(PixelOrColor3.B * 255), 0, 255)
		return Pixel
	end
end

local function CheckPixel(Pixel: Pixel)
	if Pixel[1] > 255 or Pixel[1] < 0 then
		error("[Quantize] Red value in Pixel is not in range 0..255")
        elseif Pixel[2] > 255 or Pixel[2] < 0 then
		error("[Quantize] Green value in Pixel is not in range 0..255")
        elseif Pixel[3] > 255 or Pixel[3] < 0 then
		error("[Quantize] Blue value in Pixel is not in range 0..255")
        end
        return Pixel
end

local function SortQueue(Queue: PriorityQueue, Comparator: Comparator)
	if not Queue.__sorted then
		table.sort(Queue.VolumeBoxes, Comparator)
		Queue.__sorted = true
	end
end
		
local function GetColorIndex(R: number, G: number, B: number)
	return bit32.lshift(R, 2 * Sigbits) + bit32.lshift(G, Sigbits) + B
end

local function OccupancySizeSort(A: VolumeBox, B: VolumeBox)
	return A:Count() * A:Volume() > B:Count() * B:Volume()
end
	
local function CountSort(A: VolumeBox, B: VolumeBox)
	return A:Count() > B:Count()
end

local function ReverseTable<T>(Tbl: {T})
	for Index = 1, #Tbl // 2 do
		local SwapIndex = (#Tbl - Index) + 1
		local Original = Tbl[Index]
		Tbl[Index] = Tbl[SwapIndex]
		Tbl[SwapIndex] = Original
	end 
	return Tbl
end

-- Modified from:
-- https://github.com/Roblox/luau-polyfill/blob/main/modules/collections/src/Array/reduce.lua
local function GetArraySum(Tbl: {number})
	if #Tbl == 0 then return 0 end
	local Sum = 0
	
	for _, Value in Tbl do
		Sum += Value
	end
	return Sum
end

local function To32Bit(N: number)
	return bit32.band(N, ConversionHex)
end

-- 3d color space box

local VolumeBoxPrototype = {}
VolumeBoxPrototype.__index = VolumeBoxPrototype

function VolumeBoxPrototype.Volume(self: VolumeBox, Force: boolean?)
	if Force or not self.__volume then
		self.__volume = ((self.RedMax - self.RedMin) + 1)
			* ((self.GreenMax - self.GreenMin) + 1)
			* ((self.BlueMax - self.BlueMin) + 1)
	end
	return self.__volume
end
			
function VolumeBoxPrototype.Count(self: VolumeBox, Force: boolean?)
	if Force or not self.__count then
		local PixelCount = 0
		
		for R = self.RedMin, self.RedMax do
			for G = self.GreenMin, self.GreenMax do
				for B = self.BlueMin, self.BlueMax do
					PixelCount += self.Histo[GetColorIndex(R, G, B)] or 0
				end
			end
		end
					
		self.__count = PixelCount
		return PixelCount
	else
		return self.__count
	end
end
			
function VolumeBoxPrototype.Average(self: VolumeBox, Force: boolean?)
	if Force or not self.__average_pixel then
		local GreenSum = 0
		local BlueSum = 0
		local RedSum = 0
		local NTOT = 0
					
		for R = self.RedMin, self.RedMax do
			for G = self.GreenMin, self.GreenMax do
				for B = self.BlueMin, self.BlueMax do
					local Hue = self.Histo[GetColorIndex(R, G, B)] or 0
					GreenSum += (Hue * (G + 0.5)) * VboxAvgMult
					BlueSum += (Hue * (B + 0.5)) * VboxAvgMult
					RedSum += (Hue * (R + 0.5)) * VboxAvgMult
					NTOT += Hue
				end
			end
		end

		local AveragePixel = table.create(3)
		
		if NTOT > 0 then
			AveragePixel[1] = To32Bit(RedSum / NTOT)
			AveragePixel[2] = To32Bit(GreenSum / NTOT)
			AveragePixel[3] = To32Bit(BlueSum / NTOT)
		else
			-- print("empty box")
			AveragePixel[1] = To32Bit((VboxAvgMult * (self.RedMin + self.RedMax + 1)) / 2)
			AveragePixel[2] = To32Bit((VboxAvgMult * (self.GreenMin + self.GreenMax + 1)) / 2)
			AveragePixel[3] = To32Bit((VboxAvgMult * (self.BlueMin + self.BlueMax + 1)) / 2)
		end
		
		self.__average_pixel = AveragePixel
		return AveragePixel
	else
		return self.__average_pixel
	end
end

function VolumeBoxPrototype.__len(self: VolumeBox)
	return self:Count()
end

function VolumeBoxPrototype.Copy(self: VolumeBox)
	return (setmetatable({
		GreenMin = self.GreenMin,
		GreenMax = self.GreenMax,
		BlueMin = self.BlueMin,
		BlueMax = self.BlueMax,
		RedMin = self.RedMin,
		RedMax = self.RedMax,
		Histo = self.Histo,

		__average_pixel = self.__average_pixel,
		__volume = self.__volume,
		__count = self.__count,
	}, VolumeBoxPrototype) :: any) :: VolumeBox
end
		
-- Color map
local ColorMapPrototype = {}
ColorMapPrototype.__index = ColorMapPrototype

function ColorMapPrototype.Nearest(self: ColorMap, PixelOrColor3: Pixel | Color3)
	local Pixel = GetOrCreatePixel(PixelOrColor3)
	local D1 = math.huge
	local Nearest
			
	for _, Color in self.Colors do
		local D2 = math.sqrt(
			math.pow(Pixel[1] - Color.Pixel[1], 2) +
			math.pow(Pixel[2] - Color.Pixel[2], 2) +
			math.pow(Pixel[3] - Color.Pixel[3], 2)
		)
		
		if D2 < D1 then
			Nearest = Color
			D1 = D2
		end
	end	
	return Nearest
end

function ColorMapPrototype.Map(self: ColorMap, PixelOrColor3: Pixel | Color3)
	local Pixel = GetOrCreatePixel(PixelOrColor3)
	local RedValue = bit32.rshift(Pixel[1], Shift)
	local GreenValue = bit32.rshift(Pixel[2], Shift)
	local BlueValue = bit32.rshift(Pixel[3], Shift)

	for _, Color in self.Colors do
		if RedValue >= Color.RedMin and RedValue <= Color.RedMax and
			GreenValue >= Color.GreenMin and GreenValue <= Color.GreenMax and
			BlueValue >= Color.BlueMin and BlueValue <= Color.BlueMax
		then
			return Color.Pixel
		end
	end
	return self:Nearest(Pixel)
end

function ColorMapPrototype.Palette(self: ColorMap)
	local Pixels = table.create(#self.Colors)
		
	for Index, Color in self.Colors do
		Pixels[Index] = table.clone(Color.Pixel)
	end
	return Pixels
end
			
function ColorMapPrototype.__len(self: ColorMap)
	return #self.Colors
end

local function VolumeBoxFromPixels(Pixels: {Pixel}, Histo: {number})
	local GreenMin = 1000000
	local GreenMax = 0
	local BlueMin = 1000000
	local BlueMax = 0
	local RedMin = 1000000
	local RedMax = 0
				
	for _, Pixel in Pixels do
		local GreenValue = bit32.rshift(Pixel[2], Shift)
		local BlueValue =  bit32.rshift(Pixel[3], Shift)
		local RedValue = bit32.rshift(Pixel[1], Shift)

		if RedValue < RedMin then 
			RedMin = RedValue
		elseif RedValue > RedMax then
			RedMax = RedValue
		end

		if GreenValue < GreenMin then
			GreenMin = GreenValue
		elseif GreenValue > GreenMax then
			GreenMax = GreenValue
		end

		if BlueValue < BlueMin then
			BlueMin = BlueValue
		elseif BlueValue > BlueMax then
			BlueMax = BlueValue
		end
	end
	
	return (setmetatable({
		RedMin = RedMin,
		RedMax = RedMax,
		GreenMin = GreenMin,
		GreenMax = GreenMax,
		BlueMin = BlueMin,
		BlueMax = BlueMax,
		Histo = Histo,
	}, VolumeBoxPrototype) :: any) :: VolumeBox
end

local function DoCut(
	MaxString: string,
	MinString: string,
	MaxNumber: number,
	MinNumber: number,
	VolumeBox: VolumeBox,
	PartialSum: {number},
	LookAheadSum: {number},
	Total: number
): {VolumeBox}?
	for Index = MinNumber, MaxNumber do
		if PartialSum[Index] > Total / 2 then
			local VolumeBox1 = VolumeBox:Copy()
			local VolumeBox2 = VolumeBox:Copy()
			local Left = Index - MinNumber
			local Right = MaxNumber - 1
			
			local D2 = if Left <= Right then
				math.min(MaxNumber - 1, To32Bit((Index + Right) / 2))
			else
				math.max(MinNumber, To32Bit((Index - 1) - (Left / 2)))

			-- avoid 0-count boxes
			while PartialSum[D2] == 0 or not PartialSum[D2] do
				D2 += 1
			end

			local Count2 = LookAheadSum[D2]

			while not Count2 and PartialSum[D2 - 1] do
				D2 -= 1
				Count2 = LookAheadSum[D2]
			end
            
			-- set dimensions
			VolumeBox1[MaxString] = D2
			VolumeBox2[MinString] = D2 + 1
			
			local VolumeBoxes = table.create(2)
			VolumeBoxes[1] = VolumeBox1
			VolumeBoxes[2] = VolumeBox2
			return VolumeBoxes
		end
	end

    return nil
end

local function MedianCutApply(Histo: {number}, VolumeBox: VolumeBox): {VolumeBox}?
	if #VolumeBox == 1 then
		-- only one pixel, no split
		return table.create(1, VolumeBox:Copy())
	elseif #VolumeBox == 0 then
		return nil
	end
	
	local GW = (VolumeBox.GreenMax - VolumeBox.GreenMin) + 1
	local BW = (VolumeBox.BlueMax - VolumeBox.BlueMin) + 1
	local RW = (VolumeBox.RedMax - VolumeBox.RedMin) + 1
	local MaxW = math.max(RW, GW, BW)

	-- Find the partial sum arrays along the selected axis.
	local PartialSum = {}
	local Total = 0

	if MaxW == RW then
		for R = VolumeBox.RedMin, VolumeBox.RedMax do
			local Sum = 0

			for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
				for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
					Sum += Histo[GetColorIndex(R, G, B)] or 0
				end
			end

			Total += Sum
			PartialSum[R] = Total
		end
	elseif MaxW == GW then
		for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
			local Sum = 0

			for R = VolumeBox.RedMin, VolumeBox.RedMax do
				for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
					Sum += Histo[GetColorIndex(R, G, B)] or 0
				end
			end

			Total += Sum
			PartialSum[G] = Total
		end
	else
		for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
			local Sum = 0

			for R = VolumeBox.RedMin, VolumeBox.RedMax do
				for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
					Sum += Histo[GetColorIndex(R, G, B)] or 0
				end
			end

			Total += Sum
			PartialSum[B] = Total
		end
	end
	local LookAheadSum = table.create(#PartialSum)
			
	for Index, Value in PartialSum do
		LookAheadSum[Index] = Total - Value
	end

	-- Determine the cut planes
	if MaxW == GW then
		return DoCut("GreenMax", "GreenMin", VolumeBox.GreenMax, VolumeBox.GreenMin, VolumeBox, PartialSum, LookAheadSum, Total)
	elseif MaxW == BW then
		return DoCut("BlueMax", "BlueMin", VolumeBox.BlueMax, VolumeBox.BlueMin, VolumeBox, PartialSum, LookAheadSum, Total)
	else
		return DoCut("RedMax", "RedMin", VolumeBox.RedMax, VolumeBox.RedMin, VolumeBox, PartialSum, LookAheadSum, Total)
   	 end
end

-- inner function to do the iteration
local function Iterate(Target: number, Queue: PriorityQueue, Histo: {number}, Comparator: Comparator)
	local PixelCount = #Queue.VolumeBoxes
	local Niters = 0

	while Niters < MaxIterations do
		-- Doing the checks at the top like this PR:
		-- https://github.com/olivierlesnicki/quantize/pull/6
		if PixelCount >= Target or Niters > MaxIterations then return end
		--[[
			if Niters > MaxIterations then
				warn("[Quantize] infinite loop; perhaps too few pixels!")
				return
			end
		--]]

		SortQueue(Queue, Comparator)
		local VolumeBox = table.remove(Queue.VolumeBoxes) :: VolumeBox

		-- just put it back
		if #VolumeBox == 0 then
			table.insert(Queue.VolumeBoxes, VolumeBox)
			Niters += 1
			continue
		end
		Queue.__sorted = false

		-- do the cut
		local VolumeBoxes = MedianCutApply(Histo, VolumeBox)

		if not VolumeBoxes then
			warn("[Quantize] MedianCutApply failed!")
			return
		elseif not VolumeBoxes[1] then
			warn("[Quantize] VolumeBox1 not defined; shouldn't happen!")
			return
		end
		table.insert(Queue.VolumeBoxes, VolumeBoxes[1])

		if VolumeBoxes[2] then
			table.insert(Queue.VolumeBoxes, VolumeBoxes[2])
			PixelCount += 1
		end

		Niters += 1
	end
end

local function GeneralQuantization(Pixels: {}, MaxColors: number, Options: GeneralQuantizeOptions?)
	local Outdepth = Options.Outdepth
	local Height = Options.Height
	local Width = Options.Width
				
	-- short-circuit
	if #Pixels == 0 then
		error("[Quantize] Pixel array must have atleast 1 index")
	elseif MaxColors < 2 or MaxColors > 256 then
		error("[Quantize] MaxColors has to be in range 2..256")
	elseif Outdepth then
		if Outdepth ~= 1 or Outdepth ~= 2 or Outdepth ~= 4 or Outdepth ~= 8 then
			error("[Quantize] Outdepth does not equal 1, 2, 4, or 8")
		elseif MaxColors > 2 ^ Outdepth then 
			error("[Quantize] MaxColors is greater than 2 ^ Outdepth")
		end
	end
	local NewPixels: {Pixel} = if typeof(Pixels[1]) == "table" then Pixels else table.clone(Pixels)

	-- array clone detection, as a clone wont be equal to the original
	if Pixels ~= NewPixels then
		for Index, Value in NewPixels do
			NewPixels[Index] = GetOrCreatePixel(Value)
		end
	end

	-- TODO: check color content and convert to grayscale if insufficient
	-- Determine if the image has sufficient color content.
	-- If pixfract << 1, most pixels are close to black or white.
	-- If colorfract << 1, the pixels that are not near
	-- black or white have very little color.
	-- If with little color, quantize with a grayscale colormap.

	if Options.CheckGreyscale then	
		local PixelFraction, ColorFraction = GetColorFraction(Pixels, 20, 244, 20)
						
		if PixelFraction * ColorFraction < 0.00025 then
			print(string.format(
				"Pixel fraction neither white nor black = %6.3f\nColor fraction of those pixels = %6.3f\nQuantizing in gray",
				PixelFraction,
				ColorFraction
			)
			local Colors = table.create(255)

			for Index = 1, 255 do
				Colors[Index] = {
					Pixel = table.create(3, (255 * Index) / (255 - 1))
				}
			end
			return (setmetatable({Colors = Colors}, ColorMapPrototype) :: any
		end
	end
					
	-- histo (1-d array, giving the number of pixels in
	-- each quantized region of color space), or nil on error
	local Histo = table.create(HistoSize)
	
	for _, Pixel in NewPixels do
		local Index = GetColorIndex(
			bit32.rshift(Pixel[1], Shift),
			bit32.rshift(Pixel[2], Shift),
			bit32.rshift(Pixel[3], Shift)
		)
		Histo[Index] = (Histo[Index] or 0) + 1
	end

	if #Histo > MaxColors then
		-- Ported mostly from:
		-- https://github.com/DanBloomberg/leptonica/blob/e09c1f283aa5a896facc297b617775373519d450/src/colorquant2.c#L391
		local ColorAmount = Outdepth or 0

		if not Outdepth then
			for Index = 1, HistoSize do
				if Histo[Index] then
					ColorAmount += 1
				end
			end
		end

		local ColorsSize = if ColorAmount <= 2 then
				PaletteSize2
			elseif ColorAmount <= 4 then
				PaletteSize4
			elseif ColorAmount <= 16 then
				PaletteSize16
			else
				PaletteSize0
		local Colors = table.create(ColorsSize)        

		for Index = 1, HistoSize do
			if Histo[Index] then
				local Pixel = table.create(3)
				Pixel[1] = bit32.lshift(bit32.rshift(Index, (2 * Sigbits)), Shift)
				Pixel[2] = bit32.lshift(bit32.band(bit32.rshift(Index, Sigbits), Mask), Shift)
				Pixel[3] = bit32.lshift(bit32.band(Index, Mask), Shift)
				Colors[#Colors + 1] = Pixel

				if #Colors > ColorsSize then break end
				Histo[Index] = Index + 1
			end
		end
		return (setmetatable({Colors = Colors}, ColorMapPrototype) :: any
	else	
		-- get the beginning vbox from the colors
		local VolumeBox = VolumeBoxFromPixels(NewPixels, Histo)
		local VolumeBoxes = table.create(1, VolumeBox)
		local PriorityQueue = {
			VolumeBoxes = VolumeBoxes,
			__sorted = false,
		}
  
		-- first set of colors, sorted by population
		Iterate(FractByPopulations * MaxColors, PriorityQueue, Histo, CountSort)

		-- Re-sort by the product of pixel occupancy times the size in color space.
		-- deviation: rather than creating a whole new queue to basically
		-- reverse the queue, we just reverse the queue
		SortQueue(PriorityQueue, CountSort)
		ReverseTable(VolumeBoxes)

		-- next set - generate the median cuts using the (npix * vol) sorting.
		Iterate(MaxColors, PriorityQueue, Histo, OccupancySizeSort)

		-- calculate the actual colors
		SortQueue(PriorityQueue, OccupancySizeSort)
		ReverseTable(VolumeBoxes)

		--[[
		-- XXX: won't  work yet
		table.sort(ColorMap.Palette, function(A, B)
			return GetArraySum(A) > GetArraySum(B)
		end)

		-- force darkest color to black if everything < 5
		local Lowest = ColorMap.Palette[1]
	
		if Lowest[1] < 5 and Lowest[2] < 5 and Lowest[3] < 5 then
			Lowest = table.create(3, 0)
		end

		-- force lightest color to white if everything > 251
		-- deviation: switched #VolumeBoxes - 1 to just #VolumeBoxes
		local Highest = ColorMap.Palette[#ColorMap.Palette]

		if Highest[1] > 251 and Highest[2] > 251 and Highest[3] > 251 then
			Highest.__average_pixel = table.create(3, 255)
		end
		--]]
		return setmetatable({
			Colors = VolumeBoxes
		}, ColorMapPrototype) :: any
	end
end

return Quantize :: ((Pixels: {Pixel}, MaxColors: number, Outdepth: number?) -> ColorMap) & ((Color3s: {Color3}, MaxColors: number, Outdepth: number?) -> ColorMap)
