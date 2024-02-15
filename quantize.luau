--!optimize 2
--!strict

-- Quantize.luau
-- A fully typed Luau module for MMCQ color quantization. 
-- With added support for Color3s to be used instead of RGB arrays. 
-- Based on quantize.js and Leptonica.
-- @Kalrnlo
-- 14/02/2024

-- TODO:
-- Remove greyscale method, and implement it into the quantize function
-- like leptronica https://github.com/DanBloomberg/leptonica/blob/e09c1f283aa5a896facc297b617775373519d450/src/colorquant2.c#L533
-- Add in Mixed & MixedFewColor quantize methods from leptronica (possibly)

type Comparator = (A: VolumeBoxStruct, B: VolumeBoxStruct) -> boolean

type BaseColorData = {
	RedMin: nil,
	RedMax: nil,
	GreenMin: nil,
	GreenMax: nil,
	BlueMin: nil,
	BlueMax: nil,
	Pixel: Pixel
}

-- Replacement for volume boxes so stuff like map will still work
type VolumeColorData = {
	RedMin: number,
	RedMax: number,
	GreenMin: number,
	GreenMax: number,
	BlueMin: number,
	BlueMax: number,
	Pixel: Pixel,
	Volume: nil,
	Count: nil,
	Histo: nil,
}

type ColorData = BaseColorData | VolumeColorData

type VolumeBoxStruct =  {
	RedMin: number,
	RedMax: number,
	GreenMin: number,
	GreenMax: number,
	BlueMin: number,
	BlueMax: number,
	Pixel: Pixel?,
	Volume: number?,
	Count: number?,
	Histo: {number},
}

type PriorityQueue = {
	VolumeBoxes: {VolumeBoxStruct},
	__sorted: boolean
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

export type ColorMap = typeof(setmetatable({} :: {
	Colors: {BaseColorData | VolumeColorData},
	Histo: {number}?,
}, {} :: ColorMapPrototype))

export type GeneralOptions = {
	AllowGreyscale: boolean?,
	OutputSize: number?,
}

export type MixedOptions = {
	LightThreshold: number?,
	DiffThreshold: number?,
	DarkThreshold: number?,
}

export type FewColorsOptions = {
	ColorsPerSignificantPixel: number?,
	LightThreshold: number?,
	DiffThreshold: number?,
	DarkThreshold: number?,
	GreyAmount: number?,
	MaxColors: number?,
}

--[[
    Commented out as luau doesnt type this correctly rn
    export type Pixel = {number} | {
	    ["1"]: number,
	    ["2"]: number,
	    ["3"]: number,
    }
--]]

export type Pixel = {number}

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
local SimpleOptions = {
	AllowGreyscale = true
}

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

local function To32Bit(N: number)
	return bit32.band(N, ConversionHex)
end

local function VolumeBoxStructToColorData(VolumeBox: VolumeBoxStruct): VolumeColorData
	VolumeBox.Volume = nil
	VolumeBox.Count = nil
	VolumeBox.Histo = nil :: any
	return VolumeBox :: any
end

-- pixColorFraction(pixs, 20, 244, 20, factor, &pixfract, &colorfract);
local function GetColorFraction(
	Pixels: {Pixel},
	DarkThreshold: number,
	LightThreshold: number,
	DiffThreshold: number,
	Factor: number
)
	local ColorCount = 0
	local PixelCount = 0
	local Total = 0

	for Index = 1, #Pixels, Factor do
		local Pixel = Pixels[Index]
		if not Pixel then 
			print("didnt find") 
			continue
		else
			print("found!!")
		end
		Total += 3
		-- near white
		local MinValue = math.min(Pixel[1], Pixel[2], Pixel[3])
		if MinValue > LightThreshold then continue end

		-- near black
		local MaxValue = math.max(Pixel[1], Pixel[2], Pixel[3]) 
		if MaxValue < DarkThreshold then continue end

		PixelCount += 3
		if MaxValue - MinValue >= DiffThreshold then
			ColorCount += 3
		end
	end
	
	print("fract data")
	print(PixelCount)
	print(ColorCount)
	print(PixelCount / Total, ColorCount / PixelCount)
	return PixelCount / Total, ColorCount / PixelCount
end

local function GetOrCreatePixel(PixelOrColor3: Pixel | Color3): Pixel
	if typeof(PixelOrColor3) == "table" then
		if PixelOrColor3[1] > 255 or PixelOrColor3[1] < 0 then
			error("[Quantize] Red value in Pixel is not in range 0..255")
		elseif PixelOrColor3[2] > 255 or PixelOrColor3[2] < 0 then
			error("[Quantize] Green value in Pixel is not in range 0..255")
		elseif PixelOrColor3[3] > 255 or PixelOrColor3[3] < 0 then
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

local function SortQueue(Queue: PriorityQueue, Comparator: Comparator)
	if not Queue.__sorted then
		table.sort(Queue.VolumeBoxes, Comparator)
		Queue.__sorted = true
	end
end
		
local function GetColorIndex(R: number, G: number, B: number)
	return bit32.lshift(R, 2 * Sigbits) + bit32.lshift(G, Sigbits) + B
end

local function GetPaletteSize(ColorCount: number)
	if ColorCount <= 2 then
		return PaletteSize2
	elseif ColorCount <= 4 then
		return PaletteSize4
	elseif ColorCount <= 16 then
		return PaletteSize16
	else
		return PaletteSize0
	end
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

local function GetPixelSum(Pixel: Pixel)
	return (Pixel[1] + Pixel[2]) + Pixel[3]
end

-- 3d color space box

local function SetOrGetVolumeBoxAverage(VolumeBox: VolumeBoxStruct | VolumeColorData, Histo: {number}?): Pixel
	if not VolumeBox.Pixel then
		local Histo: {number} = if Histo then Histo else VolumeBox.Histo :: any
		local GreenSum = 0
		local BlueSum = 0
		local RedSum = 0
		local NTOT = 0
					
		for R = VolumeBox.RedMin, VolumeBox.RedMax do
			for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
				for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
					local Hue = Histo[GetColorIndex(R, G, B)] or 0
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
			AveragePixel[1] = To32Bit((VboxAvgMult * (VolumeBox.RedMin + VolumeBox.RedMax + 1)) / 2)
			AveragePixel[2] = To32Bit((VboxAvgMult * (VolumeBox.GreenMin + VolumeBox.GreenMax + 1)) / 2)
			AveragePixel[3] = To32Bit((VboxAvgMult * (VolumeBox.BlueMin + VolumeBox.BlueMax + 1)) / 2)
		end
		
		VolumeBox.Pixel = AveragePixel
		return AveragePixel
	else
		return VolumeBox.Pixel
	end
end

local function SetOrGetVolumeBoxCount(VolumeBox: VolumeBoxStruct, Histo: {number}?)
	if not VolumeBox.Count then
		local Histo = Histo or VolumeBox.Histo :: {number}
		local PixelCount = 0
		
		for R = VolumeBox.RedMin, VolumeBox.RedMax do
			for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
				for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
					PixelCount += Histo[GetColorIndex(R, G, B)] or 0
				end
			end
		end
					
		VolumeBox.Count = PixelCount
		return PixelCount
	else
		return VolumeBox.Count
	end
end

local function SetOrGetVolumeBoxVolume(VolumeBox: VolumeBoxStruct): number
	if not VolumeBox.Volume then
		VolumeBox.Volume = (VolumeBox.RedMax - VolumeBox.RedMin + 1)
			* (VolumeBox.GreenMax - VolumeBox.GreenMin + 1)
			* (VolumeBox.BlueMax - VolumeBox.BlueMin + 1)
	end
	return VolumeBox.Volume :: any
end

-- Color map
local ColorMapPrototype = {}
ColorMapPrototype.__index = ColorMapPrototype

function ColorMapPrototype.Nearest(self: ColorMap, PixelOrColor3: Pixel | Color3)
	local Pixel = GetOrCreatePixel(PixelOrColor3)
	local ShortestDistance = math.huge
	local Nearest
			
	for _, Color in self.Colors do
		local ColorPixel = if Color.RedMax then SetOrGetVolumeBoxAverage(Color, self.Histo) else Color.Pixel
		local Distance = math.sqrt(
			math.pow(Pixel[1] - ColorPixel[1], 2) +
			math.pow(Pixel[2] - ColorPixel[2], 2) +
			math.pow(Pixel[3] - ColorPixel[3], 2)
		)
		
		if Distance < ShortestDistance then
			ShortestDistance = Distance
			Nearest = ColorPixel
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
		-- Checking if it has volume box data, and if it doesnt we break
		-- as the ColorMap wasnt made using volume boxes
		if not Color.RedMax then break end
		local ColorPixel = Color.Pixel or SetOrGetVolumeBoxAverage(Color, self.Histo)
			
		if RedValue >= Color.RedMin and RedValue <= Color.RedMax and
			GreenValue >= Color.GreenMin and GreenValue <= Color.GreenMax and
			BlueValue >= Color.BlueMin and BlueValue <= Color.BlueMax
		then
			return ColorPixel
		end
	end
	return self:Nearest(Pixel)
end

function ColorMapPrototype.Palette(self: ColorMap)
	local Pixels = table.create(#self.Colors)
		
	for Index, Color in self.Colors do
		local ColorPixel = if Color.RedMax then SetOrGetVolumeBoxAverage(Color, self.Histo) else Color.Pixel
		Pixels[Index] = table.clone(ColorPixel)
	end
	return Pixels
end
			
function ColorMapPrototype.__len(self: ColorMap)
	return #self.Colors
end

local function VolumeBoxFromPixels(Pixels: {Pixel}, Histo: {number})
	local GreenMin = math.huge
	local GreenMax = 0
	local BlueMin = math.huge
	local BlueMax = 0
	local RedMin = math.huge
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
	
	return {
		RedMin = RedMin,
		RedMax = RedMax,
		GreenMin = GreenMin,
		GreenMax = GreenMax,
		BlueMin = BlueMin,
		BlueMax = BlueMax,
		Histo = Histo,
	} :: VolumeBoxStruct
end

local function MedianCutApply(VolumeBox: VolumeBoxStruct, Histo: {number}): (VolumeBoxStruct?, VolumeBoxStruct?)
	local Count = SetOrGetVolumeBoxCount(VolumeBox, Histo)

	if Count == 1 then
		-- only one pixel, no split
		return table.clone(VolumeBox), nil
	elseif Count == 0 then
		return nil, nil
	end

	-- If the vbox occupies just one element in color space, it can't
	-- be split.  Leave the 'sortparam' field at 0, so that it goes to
	-- the tail of the priority queue and stays there, thereby avoiding
	-- an infinite loop (take off, put back on the head) if it
	-- happens to be the most populous box!
	local GW = (VolumeBox.GreenMax - VolumeBox.GreenMin) + 1
	local BW = (VolumeBox.BlueMax - VolumeBox.BlueMin) + 1
	local RW = (VolumeBox.RedMax - VolumeBox.RedMin) + 1

	-- Select the longest axis for splitting
	local MaxW = math.max(RW, GW, BW)

	-- Find the partial sum arrays along the selected axis.
	-- Then determine the cut planes, making sure that two vboxes
	-- are always produced.  Generate the two vboxes and compute
	-- the sum in each of them.  Choose the cut plane within
	-- the greater of the (left, right) sides of the bin in which
	-- the median pixel resides.  Here's the surprise: go halfway
	-- into that side.  By doing that, you technically move away
	-- from "median cut," but in the process a significant number
	-- of low-count vboxes are produced, allowing much better
	-- reproduction of low-count spot colors.
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

			Total += To32Bit(Sum)
			PartialSum[R] = Total
		end

		for Index = VolumeBox.RedMin, VolumeBox.RedMax do
			if PartialSum[Index] > To32Bit(Total / 2) then
				local VolumeBox1 = table.clone(VolumeBox)
				local VolumeBox2 = table.clone(VolumeBox)
				local Left = Index - VolumeBox.RedMin
				local Right = VolumeBox.RedMax - Index
			
				local CopyRedMax2 = if Left <= Right then
					math.min(VolumeBox.RedMax - 1, To32Bit((Index + Right) / 2))
				else
					math.max(VolumeBox.RedMin, To32Bit((Index - 1) - (Left / 2)))

				VolumeBox2.RedMax = To32Bit(CopyRedMax2)
				VolumeBox1.RedMin = To32Bit(CopyRedMax2 + 1)
				return VolumeBox1, VolumeBox2
			end
		end
	elseif MaxW == GW then
		for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
			local Sum = 0

			for R = VolumeBox.RedMin, VolumeBox.RedMax do
				for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
					Sum += Histo[GetColorIndex(R, G, B)] or 0
				end
			end

			Total += To32Bit(Sum)
			PartialSum[G] = Total
		end

		for Index = VolumeBox.GreenMin, VolumeBox.GreenMax do
			if PartialSum[Index] > Total / 2 then
				local VolumeBox1 = table.clone(VolumeBox)
				local VolumeBox2 = table.clone(VolumeBox)
				local Left = Index - VolumeBox.GreenMin
				local Right = VolumeBox.GreenMax - Index
			
				local CopyGreenMax2 = if Left <= Right then
					math.min(VolumeBox.GreenMax - 1, To32Bit((Index + Right) / 2))
				else
					math.max(VolumeBox.GreenMin, To32Bit((Index - 1) - (Left / 2)))

				VolumeBox2.GreenMax = To32Bit(CopyGreenMax2)
				VolumeBox1.GreenMin = To32Bit(CopyGreenMax2 + 1)
				return VolumeBox1, VolumeBox2
			end
		end
	else
		for B = VolumeBox.BlueMin, VolumeBox.BlueMax do
			local Sum = 0

			for R = VolumeBox.RedMin, VolumeBox.RedMax do
				for G = VolumeBox.GreenMin, VolumeBox.GreenMax do
					Sum += Histo[GetColorIndex(R, G, B)] or 0
				end
			end

			Total += To32Bit(Sum)
			PartialSum[B] = Total
		end

		for Index = VolumeBox.BlueMin, VolumeBox.BlueMax do
			if PartialSum[Index] > Total / 2 then
				local VolumeBox1 = table.clone(VolumeBox)
				local VolumeBox2 = table.clone(VolumeBox)
				local Left = Index - VolumeBox.BlueMin
				local Right = VolumeBox.BlueMax - Index
			
				
				local CopyBlueMax2 = if Left <= Right then
					math.min(VolumeBox.BlueMax - 1, To32Bit((Index + Right) / 2))
				else
					math.max(VolumeBox.BlueMin, To32Bit((Index - 1) - (Left / 2)))

				while PartialSum[CopyBlueMax2] == 0 or not PartialSum[CopyBlueMax2] do
					CopyBlueMax2 += 1
				end

				VolumeBox2.BlueMax = To32Bit(CopyBlueMax2)
				VolumeBox1.BlueMin = To32Bit(CopyBlueMax2 + 1)
				return VolumeBox1, VolumeBox2
			end
		end
	end

	print("[Quantize] VolumeBoxes not made; shouldn't happen")
	return nil, nil
end

-- inner function to do the iteration
local function Iterate(Target: number, Queue: PriorityQueue, Histo: {number}, Comparator: Comparator)
	local PixelCount = #Queue.VolumeBoxes
	local Niters = 0

	while Niters < MaxIterations do
		-- Doing the checks at the top like this PR:
		-- https://github.com/olivierlesnicki/quantize/pull/6
		if PixelCount >= Target or Niters > MaxIterations then return end
						
		SortQueue(Queue, Comparator)
		local VolumeBox = table.remove(Queue.VolumeBoxes) :: VolumeBoxStruct

		-- just put it back
		if SetOrGetVolumeBoxCount(VolumeBox, Histo) == 0 then
			table.insert(Queue.VolumeBoxes, VolumeBox)
			Niters += 1
			continue
		end
		Queue.__sorted = false

		-- do the cut
		local VolumeBox1, VolumeBox2 = MedianCutApply(VolumeBox, Histo)

		if not VolumeBox1 then return end
		table.insert(Queue.VolumeBoxes, VolumeBox1)

		if VolumeBox2 then
			table.insert(Queue.VolumeBoxes, VolumeBox2)
			PixelCount += 1
		end

		Niters += 1
	end
end

local function OccupancySizeSort(A: VolumeBoxStruct, B: VolumeBoxStruct)
	return SetOrGetVolumeBoxCount(A) * SetOrGetVolumeBoxVolume(A) > 
		SetOrGetVolumeBoxCount(B) * SetOrGetVolumeBoxVolume(B)
end
	
local function CountSort(A: VolumeBoxStruct, B: VolumeBoxStruct)
	return SetOrGetVolumeBoxCount(A) > SetOrGetVolumeBoxCount(B)
end

local function SumSort(A: ColorData, B: ColorData): boolean
	return GetPixelSum(SetOrGetVolumeBoxAverage(A)) > GetPixelSum(SetOrGetVolumeBoxAverage(B))
end

local function GeneralQuantization(Pixels: {}, MaxColors: number, Options: GeneralOptions?)
	local OutputSize = if Options then Options.OutputSize else nil	

	if #Pixels == 0 then
		error("[Quantize] Pixel array must have atleast 1 index")
	elseif MaxColors < 2 or MaxColors > 256 then
		error("[Quantize] MaxColors has to be in range 2..256")
	elseif OutputSize then
		print(OutputSize)
		if not ((OutputSize == 1) or (OutputSize == 2) or (OutputSize == 4) or (OutputSize == 8)) then
			error("[Quantize] OutputSize does not equal 1, 2, 4, or 8")
		elseif MaxColors > 2 ^ OutputSize then 
			print(2 ^ OutputSize)
			error("[Quantize] MaxColors is greater than 2 ^ OutputSize")
		end
	end
	local NewPixels: {Pixel} = if typeof(Pixels[1]) == "table" then Pixels else table.clone(Pixels)

	-- array clone detection, as a clone wont be equal to the original
	if Pixels ~= NewPixels then
		for Index, Value in NewPixels do
			NewPixels[Index] = GetOrCreatePixel(Value)
		end
	end

	-- Determine if the image has sufficient color content.
	-- If pixfract << 1, most pixels are close to black or white.
	-- If colorfract << 1, the pixels that are not near
	-- black or white have very little color.
	-- If with little color, quantize with a grayscale colormap.
	--[[
	if Options and Options.AllowGreyscale then	
		local PixelFraction, ColorFraction = GetColorFraction(Pixels, 20, 244, 20, math.max(1, #Pixels / 600))
						
		if PixelFraction * ColorFraction < 0.00025 then
			print(string.format(
				"Pixel fraction neither white nor black = %6.3f\nColor fraction of those pixels = %6.3f\nQuantizing in gray",
				PixelFraction,
				ColorFraction
			))
			local Palette = table.create(MaxColors)

			for Index = 1, MaxColors do
				Palette[Index] = {
					Pixel = table.create(3, To32Bit((255 * (Index - 1)) / (255 - 1)))
				}
			end
			return setmetatable({Colors = Palette}, ColorMapPrototype) :: any
		end
	end
	--]]
					
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
		print("histo is greater than max colors yeahhhh")
		local ColorCount = OutputSize or 0

		if not OutputSize then
			for Index = 1, HistoSize do
				if Histo[Index] then
					ColorCount += 1
				end
			end
		end

		local PaletteSize = GetPaletteSize(ColorCount)
		local Palette = table.create(PaletteSize)        

		for Index = 1, HistoSize do
			if Histo[Index] then
				local Pixel = table.create(3)
				Pixel[1] = bit32.lshift(bit32.rshift(Index, (2 * Sigbits)), Shift)
				Pixel[2] = bit32.lshift(bit32.band(bit32.rshift(Index, Sigbits), Mask), Shift)
				Pixel[3] = bit32.lshift(bit32.band(Index, Mask), Shift)
				Palette[#Palette + 1] = {Pixel = Pixel}

				if #Palette > PaletteSize then break end
				Histo[Index] = Index + 1
			end
		end
		return setmetatable({Colors = Palette}, ColorMapPrototype) :: any
	end	
		-- get the beginning vbox from the colors
		local VolumeBoxes = table.create(1, VolumeBoxFromPixels(NewPixels, Histo))
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
			/* Generate colormap from median cuts and quantize pixd */
			cmap = pixcmapGenerateFromMedianCuts(lh, histo, sigbits);
		--]]
		local PaletteSize = OutputSize or GetPaletteSize(#VolumeBoxes)
		--[[
			!!! ONLY NEED TO PORT NON-DITHER VERSION, 
			AS WE ARE LEAVING THAT UP TO THE USER DUE TO THE LARGE AMOUNT OF
			DITHERING METHODS THAT EXIST THAT ALL WORK BETTER IN SOME CASES ECT ECT !!!
											
			pixd = pixQuantizeWithColormap(
				pixs, ditherflag, outdepth, cmap, histo, histosize, sigbits
			);
		--]]

		if Options and Options.AllowGreyscale then
			table.sort(VolumeBoxes :: any, SumSort)

			-- force darkest color to black if everything < 5
			local Lowest = SetOrGetVolumeBoxAverage(VolumeBoxes[1])
			print("lowest", Lowest[1], Lowest[2], Lowest[3])
			if Lowest[1] < 5 and Lowest[2] < 5 and Lowest[3] < 5 then
				Lowest[1] = 0
				Lowest[2] = 0
				Lowest[3] = 0
			end

			-- force lightest color to white if everything > 251
			local Highest = SetOrGetVolumeBoxAverage(VolumeBoxes[#VolumeBoxes])
			print("highest", Highest[1], Highest[2], Highest[3])
			if Highest[1] > 251 and Highest[2] > 251 and Highest[3] > 251 then
				Highest[1] = 255
				Highest[2] = 255
				Highest[3] = 255
			end
		end

		for _, VolumeBox in VolumeBoxes do
			VolumeBoxStructToColorData(VolumeBox)
		end
																
		return setmetatable({
			Colors = VolumeBoxes,
			Histo = Histo,
		}, ColorMapPrototype) :: any
end

local function MixedQuantization(Pixels: {}, ColorsPerSignificantPixel: number, GreyAmount: number, Options: MixedOptions?)

end

local function MixedFewColorsQuantization(Pixels: {}, Options: FewColorsOptions?)

end

local function SimpleQuantization(Pixels: {})
	return GeneralQuantization(Pixels, 256, SimpleOptions)
end

local Exports = {}

Exports.Mixed = MixedQuantization :: ((Pixels: {Pixel}, ColorsPerSignificantPixel: number, GreyAmount: number, Options: MixedOptions?) -> ColorMap) & 
	((Color3s: {Color3}, ColorsPerSignificantPixel: number, GreyAmount: number, Options: MixedOptions?) -> ColorMap)

Exports.General = GeneralQuantization :: ((Pixels: {Pixel}, MaxColors: number, Options: GeneralOptions?) -> ColorMap) & 
	((Color3s: {Color3}, MaxColors: number, Options: GeneralOptions?) -> ColorMap)

Exports.MixedFewColors = MixedFewColorsQuantization :: ((Pixels: {Pixel}, Options: FewColorsOptions?) -> ColorMap) & 
	((Color3s: {Color3}, Options: FewColorsOptions?) -> ColorMap)	

Exports.Simple = SimpleQuantization :: ((Pixels: {Pixel}) -> ColorMap) & ((Color3s: {Color3}) -> ColorMap)

local function print_table(node: any)
    local cache, stack, output = {},{},{}
    local depth = 1
    local output_str = "{\n"

    while true do
        local size = #node

        local cur_index = 1
        for k,v in node :: {any} do
            if (cache[node] == nil) or (cur_index >= cache[node]) then

                if (string.find(output_str,"}",output_str:len())) then
                    output_str = output_str .. ",\n"
                elseif not (string.find(output_str,"\n",output_str:len())) then
                    output_str = output_str .. "\n"
                end

                -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
                table.insert(output,output_str)
                output_str = ""

                local key
                if (type(k) == "number" or type(k) == "boolean") then
                    key = "["..tostring(k).."]"
                else
                    key = "['"..tostring(k).."']"
                end

                if (type(v) == "number" or type(v) == "boolean") then
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = "..tostring(v)
                elseif (type(v) == "table") then
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = {\n"
                    table.insert(stack,node)
                    table.insert(stack,v)
                    cache[node] = cur_index+1
                    break
                else
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = '"..tostring(v).."'"
                end

                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
                else
                    output_str = output_str .. ","
                end
            else
                -- close the table
                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
                end
            end

            cur_index = cur_index + 1
        end

        if (size == 0) then
            output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
        end

        if (#stack > 0) then
            node = stack[#stack]
            stack[#stack] = nil
            depth += if not cache[node] then 1 else - 1
        else
            break
        end
    end

    -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
    table.insert(output,output_str)
    output_str = table.concat(output)

    print(output_str)
end
local start = os.clock()
print_table(Exports.General({
	{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
	{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
	{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
	{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
	{207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
	 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
	 {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, 
	 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190},
	  {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210},
	   {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
	    {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
		{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, 
		{211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
		 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},
		 {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
		 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
		 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
		 {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
		 {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
		  {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
		  {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, 
		  {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190},
		   {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210},
			{211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
			 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
			 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, 
			 {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
			  {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},
			  {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
			  {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
			  {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
			  {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
			  {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
			   {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
			   {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, 
			   {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190},
				{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210},
				 {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
				  {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
				  {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, 
				  {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
				   {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},
				   {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
				   {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
				   {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
				   {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
				   {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
					{176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
					{207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, 
					{176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190},
					 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210},
					  {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
					   {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
					   {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, 
					   {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
						{176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},
						{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
						{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
						{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
						{190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
						{207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
						 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, 
						 {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, 
						 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190},
						  {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210},
						   {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
							{176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
							{202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, 
							{211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207},
							 {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},
							 {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
							 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, 
							 {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, 
							 {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115}, {190,197,190}, {202,204,200}, {207,214,210}, {211,214,211}, {205,207,207}, {176, 115, 115},

}, 4, {AllowGreyscale = true}):Palette())
print("time taken", string.format("%6.3f", os.clock() - start))
