#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

/*
 * Third-Party Formula Attribution
 *
 * Upstream attribution: Knighty (see fractalforums link below in this file).
 *
 * Licensing status in this repository:
 * - Imported source snippet did not include explicit license text.
 * - Treat as third-party attributed source until upstream license is verified.
 */

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

#group PseudoKleinian

#define USE_INF_NORM

// Made by Knighty, see this thread:
// http://www.fractalforums.com/3d-fractal-generation/fragmentarium-an-ide-for-exploring-3d-fractals-and-other-systems-on-the-gpu/msg32270/#msg32270
uniform float time;
// Maximum iterations
uniform int MI; slider[0,5,50]

// Bailout
//uniform float Bailout; slider[0,20,1000]

// Size
uniform float Size; slider[0,1,2]

// Cubic fold Size
uniform vec3 CSize; slider[(0,0,0),(1,1,1),(2,2,2)]

// Julia constant
uniform vec3 C; slider[(-2,-2,-2),(0,0,0),(2,2,2)]

// Thingy thickness
uniform float TThickness; slider[0,0.01,2]

// Thingy DE Offset
uniform float DEoffset; slider[0,0,0.01]

// Thingy Translation
uniform vec3 Offset; slider[(-1,-1,-1),(0,0,0),(1,1,1)]
uniform vec3 Offset2; slider[(-2,-2,-2),(0,0,0),(2,2,2)]

float RoundBox(vec3 p, vec3 csize, float offset)
{
	vec3 di = abs(p) - csize;
	float k=max(di.x,max(di.y,di.z));
	return abs(k*float(k<0.)+ length(max(di,0.0))-offset);
}


float maxcomp(vec3 a, vec3 b) {
	return 	 a.x*b.x -  a.y*b.y,a.x*b.y + a.y * b.x;
}

float sdToBox( vec3 p, vec3 csize, float offset )
{
  vec3  di = abs(p) - csize;
  float mc = maxcomp(di, vec3(1,1,1));
  return min(mc,length(max(di,0.0))-offset);
}

float Thingy(vec3 p, float e){
	p-=Offset;
	return (abs(length(p.xy)*p.z)-e) / sqrt(dot(p,p)+abs(e));
}

float Thing2(vec3 p){
//Just scale=1 Julia box
	float DEfactor=1.;
   	vec3 ap=p+1.;
	for(int i=0;i<MI && ap!=p;i++){
		ap=p;
		p=2.*clamp(p, -CSize, CSize)-p;
      
		float r2=dot(p,p);
		orbitTrap = min(orbitTrap, abs(vec4(p,r2)));
		float k=max(Size/r2,1.);

		p*=k;DEfactor*=k;
      
		p+=C;
		orbitTrap = min(orbitTrap, abs(vec4(p,dot(p,p))));
	}
	//Call basic shape and scale its DE
	//return abs(0.5*Thingy(p,TThickness)/DEfactor-DEoffset);
	
	//Alternative shape
	
return abs(0.5*sdToBox(p,Offset2, 0.0)/DEfactor-DEoffset);
	//Just a plane
	//return abs(0.5*abs(p.z-Offset.z)/DEfactor-DEoffset);
}

float DE(vec3 p){
	return  Thing2(p);//RoundBox(p, CSize, Offset);
}









#preset default
FOV = 0.4
Eye = 3.28449,-1.22813,-2.35232
Target = 12.094,0.410074,1.61993
Up = 0.368625,0.212197,-0.905034
FocalPlane = 0.7
Aperture = 0
InFocusAWidth = 1
ApertureNbrSides = 2 NotLocked
ApertureRot = 0
ApStarShaped = false NotLocked
Gamma = 1
ToneMapping = 5
Exposure = 1.1
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 1
BloomPow = 6.7059
BloomTaps = 10
Detail = -3.1
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 713
MaxDistance = 36
Dither = 1
NormalBackStep = 10
DetailAO = -0.85715
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 1
Specular = 0.6
SpecularExp = 16
CamLight = 0.490196,0.529412,0.756863,1.72308
AmbiantLight = 1,1,1,1
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 0.682353,0.901961,1,1
LightPos = -5.6362,-0.4206,4.2268
LightSize = 0.58763
LightFallOff = 0
LightGlowRad = 0.94595
LightGlowExp = 1.06665
HardShadow = 1
ShadowSoft = 2
BaseColor = 1,1,1
OrbitStrength = 1.21
X = 0.5,0.6,0.6,-1
Y = 0.972549,0.862745,1,-0.77778
Z = 0.572549,1,0.752941,-0.17172
R = 1,0.839216,0.576471,0.55102
BackgroundColor = 0.847059,0.698039,0.490196
GradientBackground = 0
CycleColors = false
Cycles = 2.1
EnableFloor = false
FloorNormal = -0.79488,1,0.17948
FloorHeight = -1.375
FloorColor = 1,1,1
HF_Fallof = 17.0115
HF_Const = 0
HF_Intensity = 1.86588
HF_Dir = 0.01712,0.0097,-1
HF_Offset = 2.0856
HF_Color = 0.470588,0.666667,0.627451,1.10769
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 1
CloudFlatness = 0
CloudTops = 1
CloudBase = -1
CloudDensity = 1
CloudRoughness = 1
CloudContrast = 1
CloudColor = 0.65,0.68,0.7
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.7,0.5,0.3
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
MI = 35
Size = 1
CSize = 1,1,1
C = -0.49924,-1.68748,0
TThickness = 0
DEoffset = 0
Offset = 0,0,0
Offset2 = 1.088,1.08,1
#endpreset





#preset 01
FOV = 0.4
Eye = 4.79401,-1.62276,-2.2098
Target = 14.5753,-1.26871,-1.69022
FocalPlane = 0.7
Aperture = 0.01
InFocusAWidth = 1
ApertureNbrSides = 6 NotLocked
ApertureRot = 15
ApStarShaped = false
Gamma = 1
ToneMapping = 5
Exposure = 1.1
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0.32352
BloomPow = 1.0588
Detail = -3.9
FudgeFactor = 1
MaxRaySteps = 713
MaxDistance = 36
Dither = 1
NormalBackStep = 10
SpecularExp = 110.295
CamLight = 0.501961,0.756863,0.713725,1.93846
DetailAO = -1.86172
AoCorrect = 0.38889
LightPos = -10,-1.6854,3.0338
LightSize = 0.07216
LightGlowRad = 1.14865
LightGlowExp = 0.86665
HardShadow = 0
ShadowSoft = 3.4666
BaseColor = 1,1,1
OrbitStrength = 1.23
X = 0.5,0.6,0.6,-1
Y = 0.972549,0.862745,1,0.49494
Z = 0.572549,1,0.752941,0.57576
R = 1,0.839216,0.576471,0.4898
BackgroundColor = 0,0,0
GradientBackground = 0
CycleColors = true
Cycles = 3.1
EnableFloor = false
FloorNormal = -0.79488,1,0.17948
FloorHeight = -1.375
FloorColor = 1,1,1
HF_Const = 0
HF_Dir = 0.0137,0.0097,-1
HF_Offset = 2.0856
HF_Color = 0.447059,0.72549,0.847059,1.10769
MI = 35
Size = 1
CSize = 1,1,1
C = -0.49924,-1.68748,0
TThickness = 0
DEoffset = 0
Offset = 0,0,0
UpLock = false
Up = 0.0448634,0.19764,-0.979246
DofCorrect = true
Bloom = true
BloomTaps = 14
BloomStrong = 1
RefineSteps = 4
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 0.58511
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
Specular = 0.6
AmbiantLight = 1,1,1,1
Reflection = 0.596078,0.596078,0.596078
ReflectionsNumber = 4
SpotGlow = true
SpotLight = 0.682353,0.901961,1,2.5
LightFallOff = 0
ShadowBlur = 0
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
HF_Fallof = 17.0115
HF_Intensity = 1.86588
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 1
CloudFlatness = 0
CloudTops = 1
CloudBase = -1
CloudDensity = 1
CloudRoughness = 1
CloudContrast = 1
CloudColor = 0.65,0.68,0.7
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.7,0.5,0.3
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
Offset2 = 1.088,1.08,1
#endpreset
