#info Pseudo Kleinian hybrid with Megner 

#define providesInit
//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO
#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

#group The Baird Delta
uniform int Iterations;  slider[0,10,100]
uniform int mColorIterations;  slider[0,2,100]
uniform float Scale; slider[0.00,3,4.00]
uniform vec3 RotVector; slider[(0,0,0),(1,0,0),(1,1,1)]
uniform float RotAngle; slider[0.00,60,360]
uniform vec3 mOffset; slider[(-2,-2,-2),(1,0,0),(2,2,2)]

mat3 rot;

void init() {
	rot = rotationMatrix3(normalize(RotVector), RotAngle);
}

uniform float YOff; slider[0,0.333333,1]

float DE1(vec3 z)
{
	float r;
	int n = 0;
	while (n < Iterations && dot(z,z)<10000.0) {
		// Fold
		z.xy = sin(z.xy);
		if(z.y>z.x) z.xy=z.yx;
		z.y=YOff-abs(z.y-YOff);
		z.x+=1./3.;if(z.z>z.x) z.xz=z.zx; z.x-=1./3.;
		z.x-=1./3.;if(z.z>z.x) z.xz=z.zx; z.x+=1./3.;
		//z = rot *z;
		z=Scale* (z-mOffset)+mOffset;
		z = rot *z;
		r = dot(z, z);
		if (n<mColorIterations) orbitTrap = min(orbitTrap, abs(vec4(z,r)));
		n++;
	}
	//return abs(length(z)-length(mOffset)) * pow(Scale, float(-n));
	return abs(z.x-mOffset.x) * pow(Scale, float(-n));
}



#group PseudoKleinian

#define USE_INF_NORM

uniform int MI; slider[0,5,100]
uniform float Size; slider[0,1,2]
uniform vec3 CSize; slider[(0,0,0),(1,1,1),(2,2,2)]
uniform vec3 C; slider[(-2,-2,-2),(0,0,0),(2,2,2)]
uniform float DEoffset; slider[0,0,0.01]
uniform vec3 Offset; slider[(-2,-2,-2),(0,0,0),(2,2,2)]
uniform int MnIterations;  slider[0,2,20]
uniform int ColorIterations;  slider[0,2,20]
uniform float MnScale; slider[0.00,3.0,4.00]
uniform vec3 MnOffset; slider[(0,0,0),(1,1,1),(2,2,2)]

float Menger(vec3 z)
{
	float r;
	int n = 0;
	z = abs(z);
	if (z.x<z.y){ z.xy = z.yx;}
	if (z.x<z.z){ z.xz = z.zx;}
	if (z.y<z.z){ z.yz = z.zy;}
	if (z.z<1./3.){ z.z -=2.*( z.z-1./3.);}
	
while (n < MnIterations && dot(z,z)<100.0) {
		
		z=MnScale* (z-MnOffset)+MnOffset;
		z = abs(z);
		if (z.x<z.y){ z.xy = z.yx;}
		if (z.x< z.z){ z.xz = z.zx;}
		if (z.y<z.z){ z.yz = z.zy;}
		if (z.z<1./3.*MnOffset.z){ z.z -=2.*( z.z-1./3.*MnOffset.z);}
		r = dot(z-MnOffset, z-MnOffset);
		orbitTrap = min(orbitTrap, abs(vec4(z,r)));
		n++;
	}
	
	//return (length(z)-sqrt(3.) ) * pow(Scale, float(-n));
	return float(z.x-MnOffset) * pow(MnScale, float(-n));
}

float Thing2(vec3 p){
#ifdef USE_INF_NORM   
	vec3 p1=abs(p);
	float r2=max(p1.x,max(p1.y,p1.z));
#else
	float r2=dot(p,p);
#endif
	float DEfactor=1.;
	for(int i=0;i<MI && r2<60.;i++){
		p=2.*clamp(p, -CSize, CSize)-p;
      
		r2=dot(p,p);
		orbitTrap = min(orbitTrap, abs(vec4(p,r2)));
		float k=max(Size/r2,1.);
		p*=k;DEfactor*=k;
      
		p+=C;
#ifdef USE_INF_NORM   
		p1=abs(p);
		r2=max(p1.x,max(p1.y,p1.z));
#else
		 r2=dot(p,p);
#endif
		if (i < ColorIterations) orbitTrap = min(orbitTrap, abs(vec4(p,r2)));
	}

	return abs(0.5*Menger(p-Offset)/DEfactor-DEoffset);
}


float DE(vec3 pos){
	return  max(DE1(pos),Thing2(pos) );
	//return  Thing2(pos)+DE1(pos) ;
}


#preset default
FOV = 0.4
Eye = -3.36663,-7.57374,-40.9615
Target = -3.13425,-7.53874,-30.9642
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
ApertureNbrSides = 5 NotLocked
ApertureRot = 0
ApStarShaped = false
Gamma = 1
ToneMapping = 2
Exposure = 1
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 0
BloomPow = 2
BloomTaps = 4
Detail = -2.7
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 345
MaxDistance = 100
Dither = 0.5
NormalBackStep = 1
DetailAO = -0.5
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 0.686275,0.960784,1,0.46154
AmbiantLight = 1,1,1,0.34042
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.921569,0.827451,2
LightPos = 10,-1.9102,-34.8
LightSize = 0
LightFallOff = 0
LightGlowRad = 1.0811
LightGlowExp = 0.8
HardShadow = 1
ShadowSoft = 5.0666
BaseColor = 1,1,1
OrbitStrength = 1
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.388235,0.6,0.407843
GradientBackground = 0.3
CycleColors = false
Cycles = 1.1
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.94776
HF_Const = 0
HF_Intensity = 0
HF_Dir = 1,64.4,-1
HF_Offset = -8.7342
HF_Color = 1,0.870588,0.705882,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
CloudScale = 1
CloudFlatness = 0
CloudTops = 1
CloudBase = -1
CloudDensity = 1
CloudRoughness = 1
CloudContrast = 1
CloudColor = 0.65,0.68,0.7
SunLightColor = 0.7,0.5,0.3
Iterations = 10
mColorIterations = 2
Scale = 3
RotVector = 1,0,0
RotAngle = 60
mOffset = 1,0,0
YOff = -0.94
MI = 10
Size = 1
CSize = 1,1,1
C = 0,0,0
DEoffset = 0
Offset = 0,0,0
MnIterations = 2
ColorIterations = 2
MnScale = 3
MnOffset = 1,1,1
Up = 0.00184646,0.99916,-0.0035414
#endpreset

#preset 02
FOV = 0.55462
Eye = 1.74029,6.11177,-13.4199
Target = -4.4925,-0.582353,-9.37742
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
ApertureNbrSides = 5 NotLocked
ApertureRot = 0
ApStarShaped = false
Gamma = 1
ToneMapping = 2
Exposure = 1
Brightness = 1
Contrast = 2
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 0
BloomPow = 2
BloomTaps = 4
Detail = -2.7
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 345
MaxDistance = 100
Dither = 0.5
NormalBackStep = 1
DetailAO = -0.5
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 0.686275,0.960784,1,0.33846
AmbiantLight = 1,1,1,0.68086
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.815686,0.341176,1
LightPos = 4.8314,-2.3596,-10
LightSize = 0
LightFallOff = 0
LightGlowRad = 1.4865
LightGlowExp = 1.53335
HardShadow = 1
ShadowSoft = 0
BaseColor = 1,1,1
OrbitStrength = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.388235,0.6,0.407843
GradientBackground = 0.3
CycleColors = false
Cycles = 1.1
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.94776
HF_Const = 0
HF_Intensity = 0.02597
HF_Dir = 0,0,-0.59224
HF_Offset = -8.7342
HF_Color = 1,0.870588,0.705882,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
CloudScale = 1
CloudFlatness = 0
CloudTops = 1
CloudBase = -1
CloudDensity = 1
CloudRoughness = 1
CloudContrast = 1
CloudColor = 0.65,0.68,0.7
SunLightColor = 0.7,0.5,0.3
Iterations = 10
mColorIterations = 2
Scale = 3
RotVector = 1,0,0
RotAngle = 60
mOffset = 0.875,0,2
YOff = 1
MI = 10
Size = 1
CSize = 0,1,1
C = 0,0,0
DEoffset = 0
Offset = 0,0,0
MnIterations = 2
ColorIterations = 2
MnScale = 2.2
MnOffset = 1,1,1
Up = 0.747141,-0.499834,0.324262
#endpreset

#preset 01
FOV = 0.6
Eye = 7.78834,-5.3963,-41.9908
Target = 15.1222,-5.52343,-35.1938
FocalPlane = 0.15
Aperture = 0
InFocusAWidth = 0.94
ApertureNbrSides = 7 NotLocked
ApertureRot = 0
ApStarShaped = false
Gamma = 1.7
ToneMapping = 2
Exposure = 1.40427
Brightness = 1
Contrast = 2
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 0
BloomPow = 2
BloomTaps = 4
Detail = -2.7
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 1195
MaxDistance = 8.33
Dither = 0.82727
NormalBackStep = 1
DetailAO = -1.9362
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0.22222
Specular = 1
SpecularExp = 16
CamLight = 0.686275,0.960784,1,2.5
AmbiantLight = 1,1,1,1
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.635294,0.219608,1.2414
LightPos = 0,0,0
LightSize = 0.01031
LightFallOff = 0
LightGlowRad = 1.4865
LightGlowExp = 1.53335
HardShadow = 1
ShadowSoft = 0
BaseColor = 0.47451,0.47451,0.47451
OrbitStrength = 0
X = 1,1,1,1
Y = 1,0.6,0,-1
Z = 0.941176,1,0.670588,-1
R = 1,0.807843,0.611765,1
BackgroundColor = 0.192157,0.560784,0.592157
GradientBackground = 0.8
CycleColors = true
Cycles = 7.99222
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.1
HF_Const = 0
HF_Intensity = 0.03896
HF_Dir = 0,0,1
HF_Offset = -8.2278
HF_Color = 1,0.870588,0.705882,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
CloudScale = 1
CloudFlatness = 0
CloudTops = 1
CloudBase = -1
CloudDensity = 1
CloudRoughness = 1
CloudContrast = 1
CloudColor = 0.65,0.68,0.7
SunLightColor = 0.7,0.5,0.3
Iterations = 2
mColorIterations = 0
Scale = 3
RotVector = 1,0,0
RotAngle = 60
mOffset = 1,0,0
YOff = 0
MI = 30
Size = 1
CSize = 1.0046,1,1
C = 0.01244,0,0
DEoffset = 0
Offset = 0,-1,0
MnIterations = 5
ColorIterations = 0
MnScale = 2.44
MnOffset = 2,2,2
Up = -0.763947,-0.125054,0.821937
#endpreset




#preset 03
FOV = 0.76422
Eye = 5.14048,9.35884,4.99955
Target = 1.23713,8.66709,1.29
UpLock = false
FocalPlane = 0.21996
Aperture = 0
InFocusAWidth = 0.8
DofCorrect = true
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 1.1
ToneMapping = 3
Exposure = 0.6702
Brightness = 1
Contrast = 1.4
Saturation = 1.4
GaussianWeight = 2
AntiAliasScale = 2.7
BloomIntensity = 0
BloomPow = 1.5294
BloomTaps = 25
BloomStrong = 1
Detail = -3.7
RefineSteps = 4
FudgeFactor = 0.68224
MaxRaySteps = 2000
MaxDistance = 133.33
Dither = 0
NormalBackStep = 1
DetailAO = -0.52129
coneApertureAO = 1
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.81012
AO_pointlight = 0.6
AoCorrect = 0.77778
Specular = 1.6
SpecularExp = 51.47
CamLight = 0.772549,0.941176,1,2
AmbiantLight = 0.894118,0.858824,1,0.34042
Reflection = 0.243137,0.203922,0.141176
ReflectionsNumber = 1
SpotGlow = true
SpotLight = 0.756863,0.92549,1,2
LightPos = 10,10,2.809
LightSize = 1
LightFallOff = 0
LightGlowRad = 1.2838
LightGlowExp = 1.53335
HardShadow = 0
ShadowSoft = 0
ShadowBlur = 0
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 1,1,1
OrbitStrength = 0.83562
X = 0,0.592157,0.0666667,-0.17172
Y = 0.537255,0.964706,1,1
Z = 0.470588,0.835294,1,0.15152
R = 1,0.372549,0.0117647,-0.08164
BackgroundColor = 0.717647,0.690196,1
GradientBackground = 0
CycleColors = true
Cycles = 7.67634
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 1.21093
HF_Const = 0
HF_Intensity = 0.18182
HF_Dir = 1,1,0.02912
HF_Offset = 9.2406
HF_Color = 0.901961,0.921569,1,3
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
Iterations = 9
mColorIterations = 4
Scale = 2
RotVector = 0,0,1
RotAngle = 360
mOffset = 1,-1.25,-0.41668
YOff = 0
MI = 11
Size = 0.4
CSize = 0.84956,1.23894,2
C = -2,0.375,0
DEoffset = 0
Offset = 0,0,-0.80768
MnIterations = 1
ColorIterations = 5
MnScale = 0
MnOffset = 1,1,1
Up = -0.00858283,0.980363,-0.173785
#endpreset




#preset from_title1
FOV = 0.5
Eye = 7.8942,-0.15179,-2.35838
Target = 0.544716,2.77392,-8.47604
UpLock = false
Up = -0.576389,0.154867,0.766511
FocalPlane = 2.54499
Aperture = 0.08334
InFocusAWidth = 0.25758
DofCorrect = true
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.8
ToneMapping = 5
Exposure = 1
Brightness = 1
Contrast = 1.8
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.7
BloomPow = 3
BloomTaps = 20
BloomStrong = 1
Detail = -3.46787
RefineSteps = 4
FudgeFactor = 0.2
MaxRaySteps = 2000
MaxDistance = 166.67
Dither = 0.85455
NormalBackStep = 0
DetailAO = -1e-05
coneApertureAO = 0.5
maxIterAO = 11
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
Specular = 0.12244
SpecularExp = 500
CamLight = 0.85098,0.937255,1,0.43076
AmbiantLight = 0.745098,0.882353,1,0.68086
Reflection = 0.592157,0.454902,0.333333
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.678431,0.411765,0.5172
LightPos = 10,5.7304,-1.6854
LightSize = 0
LightFallOff = 0
LightGlowRad = 0.8784
LightGlowExp = 3.85
HardShadow = 1
ShadowSoft = 3.1998
ShadowBlur = 0.05719
perf = false
SSS = false
sss1 = 0.67797
sss2 = 0
BaseColor = 0.686275,0.686275,0.686275
OrbitStrength = 0.17808
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.486275,0.556863,0.6
GradientBackground = 0
CycleColors = false
Cycles = 1.1
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 5
HF_Const = 0
HF_Intensity = 0.2987
HF_Dir = 0.02912,0.53398,1
HF_Offset = -8.481
HF_Color = 0.345098,0.615686,0.619608,1.7
HF_Scatter = 0
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 1
HF_CastShadow = true
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 1.68885
CloudFlatness = 0
CloudTops = 3
CloudBase = -8.7342
CloudDensity = 0.65789
CloudRoughness = 1.42372
CloudContrast = 0
CloudColor = 0.403922,0.47451,0.545098
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.486275,0.513725,0.686275
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
Iterations = 10
mColorIterations = 2
Scale = 3
RotVector = 1,0,0
RotAngle = 60
mOffset = 1,0,0
YOff = -0.94
MI = 11
Size = 1
CSize = 1.64602,1.04424,2
C = 0.15624,0,0
DEoffset = 0
Offset = 0,0,0
MnIterations = 2
ColorIterations = 2
MnScale = 3
MnOffset = 1,1,1
#endpreset
