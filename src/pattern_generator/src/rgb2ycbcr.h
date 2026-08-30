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

#include <cmath>

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

struct YCbCrPolicy
{
	int bits;
	int colorimetry;
	int quant_range;
	int luma_scale;
	int chroma_scale;
	int offset;
	int normalizer;
	float kr;
	float kg;
	float kb;
	float cb_divisor;
	float cr_divisor;

	static YCbCrPolicy Create(int requested_bits, int requested_colorimetry,
	                         int requested_quant_range)
	{
		YCbCrPolicy policy;
		policy.bits=(requested_bits==10 || requested_bits==12) ? requested_bits : 8;
		policy.colorimetry=requested_colorimetry;
		policy.quant_range=(requested_quant_range==1) ? 1 : 2;
		const int shift=policy.bits-8;
		policy.luma_scale=(policy.quant_range==1 ? 219 : 255) << shift;
		policy.chroma_scale=(policy.quant_range==1 ? 224 : 256) << shift;
		policy.offset=128 << shift;
		policy.normalizer=(256 << shift)-1;
		if(requested_colorimetry==9) {
			policy.kr=0.2627f;
			policy.kg=0.6780f;
			policy.kb=0.0593f;
			policy.cb_divisor=1.8814f;
			policy.cr_divisor=1.4746f;
		} else {
			policy.kr=0.2126f;
			policy.kg=0.7152f;
			policy.kb=0.0722f;
			policy.cb_divisor=1.8556f;
			policy.cr_divisor=1.5748f;
		}
		return policy;
	}
};

static YCbCr RGB2YCbCr(RGB rgb, const YCbCrPolicy &policy) {
	int R, G, B;

	// Pattern values already arrive in the active draw depth selected by BITS.
	R = rgb.R;
	G = rgb.G;
	B = rgb.B;
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
	int Y = std::round(policy.kr*R + policy.kg*G + policy.kb*B);
	int Cb = std::round(((-policy.kr/policy.cb_divisor)*R
		-(policy.kg/policy.cb_divisor)*G + 0.5f*B)
		*policy.chroma_scale/policy.luma_scale + policy.offset);
	int Cr = std::round((0.5f*R-(policy.kg/policy.cr_divisor)*G
		-(policy.kb/policy.cr_divisor)*B)
		*policy.chroma_scale/policy.luma_scale + policy.offset);

	return YCbCr(Y, Cb, Cr);
}

static RGB YCbCrToRGB(YCbCr ycbcr, const YCbCrPolicy &policy) {
	/* Left-to-right (x*luma_scale)/chroma_scale keeps the legacy rounding:
	   precomputing luma_scale/chroma_scale adds a second float rounding that
	   shifts +-1 code at 12-bit limited range. */
	float r=ycbcr.Y+(ycbcr.Cr-policy.offset)*policy.luma_scale/policy.chroma_scale*policy.cr_divisor;
	float g=ycbcr.Y+(ycbcr.Cb-policy.offset)*policy.luma_scale/policy.chroma_scale
		*-policy.kb*policy.cb_divisor/policy.kg
		+(ycbcr.Cr-policy.offset)*policy.luma_scale/policy.chroma_scale
		*-policy.kr*policy.cr_divisor/policy.kg;
	float b=ycbcr.Y+(ycbcr.Cb-policy.offset)*policy.luma_scale/policy.chroma_scale*policy.cb_divisor;

	return RGB((int)r, (int)g, (int)b);
}
