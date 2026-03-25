
//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

#group PseudoKleinian

#define USE_INF_NORM

// Made by Knighty, see this thread:
// http://www.fractalforums.com/3d-fractal-generation/fragmentarium-an-ide-for-exploring-3d-fractals-and-other-systems-on-the-gpu/msg32270/#msg32270

// Maximum iterations
uniform int MI; slider[0,5,20]

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


uniform float f1; slider[0,1,2]
uniform float f2; slider[0,1,2]
uniform float f3; slider[0,1,3]
uniform float f4; slider[0,1,3]

float Shape1(vec3 p) {
return (length(p - Offset)-f1)+sin(p.x*p.y*p.z*100.0*f2)/10;
}

float RoundBox(vec3 p, vec3 csize, float offset)
{
	vec3 di = abs(p) - csize;
	float k=max(di.x,max(di.y,di.z));
	return abs(k*float(k<0.)+ length(max(di,0.0))-offset);
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
	//return abs(0.5*RoundBox(p, vec3(1.,1.,1.), 1.0)/DEfactor-DEoffset);
	//Just a plane
	//return abs(0.5*abs(p.z-Offset.z)/DEfactor-DEoffset);
	//return max(abs(0.1*f3*Shape1(p)/DEfactor-DEoffset),abs(0.1*f4*Thingy(p,TThickness)/DEfactor-DEoffset)) ;
	return mix(abs(0.1*f3*Shape1(p)/DEfactor-DEoffset),abs(0.1*f4*Thingy(p,TThickness)/DEfactor-DEoffset),sin(p.y)) ;
}

float DE(vec3 p){
	return  Thing2(p);//RoundBox(p, CSize, Offset);
}







#preset 1
FOV = 0.5
Eye = -0.0243032,-0.15619,-8.37426
Target = -2.27302,0.538759,-18.0933
UpLock = false
FocalPlane = 0.40012
Aperture = 0.01
InFocusAWidth = 1
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 1.0577
ToneMapping = 3
Exposure = 1.7742
Brightness = 1
Contrast = 1.4433
Saturation = 2.191
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.41176
BloomPow = 0.7059
BloomTaps = 14
BloomStrong = 1
Detail = -3
RefineSteps = 4
FudgeFactor = 0.34177
MaxRaySteps = 1517
MaxDistance = 33.33
Dither = 0.5
NormalBackStep = 1
DetailAO = -0.59577
coneApertureAO = 1
maxIterAO = 20
FudgeAO = 1
AO_ambient = 1.175
AO_camlight = 1.01266
AO_pointlight = 0
AoCorrect = 0
Specular = 0.09184
SpecularExp = 6
CamLight = 0.941176,0.862745,1,0.21538
AmbiantLight = 1,1,1,1
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.862745,0.619608,1
LightPos = 5.7304,-3.2584,-10
LightSize = 0.17526
LightFallOff = 0
LightGlowRad = 1.2838
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 1.6
ShadowBlur = 0.06024
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 1,1,1
OrbitStrength = 0.54795
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.14286
BackgroundColor = 0.0980392,0.243137,0.247059
GradientBackground = 0
CycleColors = true
Cycles = 1.36288
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.01
HF_Const = 0
HF_Intensity = 0.1
HF_Dir = 0,1,0
HF_Offset = 0
HF_Color = 0.843137,0.952941,1,0.36924
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
MI = 14
Size = 1.21666
CSize = 1.01786,2,0.83186
C = 0.07876,0,0
TThickness = 0
DEoffset = 0
Offset = 0.09616,0,0
f1 = 1.01562
f2 = 0.98438
f3 = 3
f4 = 1
Up = -0.26498,-0.962288,-0.00749821
#endpreset


#preset Default
FOV = 0.5
Eye = -8.68305,1.76716,-0.499091
Target = -9.14029,-8.18334,-1.38143
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
ApertureNbrSides = 5 NotLocked
ApertureRot = 0
ApStarShaped = false NotLocked
Gamma = 0.72115
ToneMapping = 5
Exposure = 1.7742
Brightness = 1
Contrast = 1.08245
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.2985
BloomPow = 0.7059
BloomTaps = 9
Detail = -2.3
FudgeFactor = 1
MaxRaySteps = 256
MaxDistance = 84.75
Dither = 0.5
NormalBackStep = 1
DetailAO = -1.11699
AoCorrect = 0
SpecularExp = 6
CamLight = 0.941176,0.862745,1,0.21538
LightPos = -5.2808,3.8726,8.2022
LightSize = 0.17526
LightGlowRad = 1.2838
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 0.8
BaseColor = 0.490196,0.490196,0.490196
OrbitStrength = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.14286
BackgroundColor = 0.0980392,0.243137,0.247059
GradientBackground = 0
CycleColors = false
Cycles = 9.57066
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Const = 0
HF_Dir = 0,1,0
HF_Offset = -6.923
HF_Color = 1,1,1,0.36924
Size = 0.15126
CSize = 1,1,1
C = -2,0,0
TThickness = 0
DEoffset = 0.01
Offset = 0,0,0
RefineSteps = 4
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
Specular = 0.09184
AmbiantLight = 1,1,1,1
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.862745,0.619608,1
LightFallOff = 0
HF_Fallof = 1.06424
HF_Intensity = 0.01316
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
MI = 5
f1 = 1
f2 = 1
f3 = 1
f4 = 1
Up = -0.950376,0.0423608,0.0147752
#endpreset
