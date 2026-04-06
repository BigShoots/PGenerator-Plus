/*
 * Copyright (c) 2021-2022 Juan Francisco Loya
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * See the File README and COPYING for more detail about License
 *
*/


#pragma once

class RGB
{
public:
	int R;
	int G;
	int B;

	RGB(int r, int g, int b)
	{
		R = r;// * 0.8588235 + 16.0;
		G = g;// * 0.8588235 + 16.0;
		B = b;// * 0.8588235 + 16.0;
//		R = r * 0.856305 + 16.0 << (bits - 8);
//		G = g * 0.856305 + 16.0 << (bits - 8);
//		B = b * 0.856305 + 16.0 << (bits - 8);
	}

	bool Equals(RGB rgb)
	{
		return (R == rgb.R) && (G == rgb.G) && (B == rgb.B);
	}
};

class YCbCr
{
public:
	float Y;
	float Cb;
	float Cr;


	YCbCr(float y, float cb, float cr)
	{
		Y = y;
		Cb = cb;
		Cr = cr;
	}

	bool Equals(YCbCr ycbcr)
	{
		return (Y == ycbcr.Y) && (Cb == ycbcr.Cb) && (Cr == ycbcr.Cr);
	}
};

static YCbCr RGB2YCbCr(RGB rgb, int bits, int colorimetry, int rgb_quant_range) {
	float coeffs[2][3] =
	{
	{ 0.2126, 0.7152, 0.0722}, 
	{ 0.2627, 0.6780, 0.0593}, 
	};
	/* Full range 0-255: 256/255, Studio range: 256/219, Limited range: 224/219 */
	int scalar1;
	int scalar2;
	int scalar_limit1 = 224 << (bits - 8);
	int scalar_limit2 = 219 << (bits - 8);
	int scalar_full1 = 256 << (bits - 8);
	int scalar_full2 = 255 << (bits - 8);
	int offset = 128 << (bits - 8);
	int R, G, B;
	int idx;
	float d, e;
	
	R = rgb.R * ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));  //x10 = (2^10 - 1) / (2^8 - 1) * x8, where x8 and x10 are 8 and 10 bit values respectively.
	G = rgb.G * ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));
	B = rgb.B * ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));	
//	if (bits == 8) {
//		R = R * 0.85588235 + 16;
//		G = G * 0.85588235 + 16;
//		B = B * 0.85588235 + 16;
//	} 
//	if (bits == 10) {
//		R = R * 0.856305 + 64;
//		G = G * 0.856305 + 64;
//		B = B * 0.856305 + 64;
//	}	
	if (rgb_quant_range == 1) {
		scalar1=scalar_limit1;
		scalar2=scalar_limit2;
	}
	if (rgb_quant_range == 2) {
		scalar1=scalar_full1;
		scalar2=scalar_full2;
	}
	if (colorimetry == 2) {
		idx = 0;
		d = 1.8556;
		e = 1.5748;
	}	
	if (colorimetry == 9) {
		idx = 1;
		d = 1.8814;
		e = 1.4746;
	}
	int Y = std::round((coeffs[idx][0] * R + coeffs[idx][1]* G + coeffs[idx][2] * B));
	int Cb = std::round(((-coeffs[idx][0]/d) * R - (coeffs[idx][1]/d) * G + ((d/2)/d) * B)*scalar1/scalar2 + offset); // Chrominance Blue
	int Cr = std::round((((e/2)/e) * R - (coeffs[idx][1]/e) * G - (coeffs[idx][2]/e) * B)*scalar1/scalar2 + offset); // Chrominance Red

	return YCbCr(Y, Cb, Cr); 
}

static RGB YCbCrToRGB(YCbCr ycbcr, int bits, int colorimetry, int rgb_quant_range) {
	float coeffs[2][3] =
	{
	{ 0.2126, 0.7152, 0.0722}, 
	{ 0.2627, 0.6780, 0.0593}, 
	};
	/* Full range 0-255: 256/255, Studio range: 256/219, Limited range: 224/219 */
	int scalar1;
	int scalar2;
	int scalar_limit1 = 224 << (bits - 8);
	int scalar_limit2 = 219 << (bits - 8);
	int scalar_full1 = 256 << (bits - 8);
	int scalar_full2 = 255 << (bits - 8);
	int offset = 128 << (bits - 8);
	int idx;
	float d, e;
	if (rgb_quant_range == 1) {
		scalar1=scalar_limit1;
		scalar2=scalar_limit2;
	}
	if (rgb_quant_range == 2) {
		scalar1=scalar_full1;
		scalar2=scalar_full2;
	}
	if (colorimetry == 2) {
		idx = 0;
		d = 1.8556;
		e = 1.5748;
	}	
	if (colorimetry == 9) {
		idx = 1;
		d = 1.8814;
		e = 1.4746;
	}	
	float r = ycbcr.Y + (ycbcr.Cr - offset) * scalar2/scalar1 * e;
	float g = ycbcr.Y + (ycbcr.Cb - offset) * scalar2/scalar1 * -coeffs[idx][2]*d/coeffs[idx][1] + (ycbcr.Cr - offset) * scalar2/scalar1 * -coeffs[idx][0]*e/coeffs[idx][1];
	float b = ycbcr.Y + (ycbcr.Cb - offset) * scalar2/scalar1 * d;

	return RGB((int)r, (int)g, (int)b);
}