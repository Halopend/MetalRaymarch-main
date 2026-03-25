#info Pseudo Kleinian hybrid with Kalibox 

#define providesInit
//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

//#include "gi2.frag"
#group PseudoKleinian
#define USE_INF_NORM

uniform int MI; slider[0,5,20]
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
		z.x = cos(z.x);
		r = dot(z-MnOffset, z-MnOffset);
		//orbitTrap = min(orbitTrap, abs(vec4(z,r)));
		n++;
	}
	
	//return (length(z)-sqrt(3.) ) * pow(Scale, float(-n));
	return float(z.x-MnOffset) * pow(MnScale, float(-n));
}

float Thing2(vec3 p){
//Just scale=1 Julia box
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
		//orbitTrap = min(orbitTrap, abs(vec4(p,r2)));
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
	//Call basic shape and scale its DE
	return abs(0.5*Menger(p-Offset)/DEfactor-DEoffset);
}

float DE1(vec3 p){
	return  Thing2(p);//RoundBox(p, CSize, Offset);

}



#group Mandelbox

uniform int Iterations;  slider[0,17,300]
uniform int mColorIterations;  slider[0,3,300]
uniform float MinRad2;  slider[0,0.25,2.0]
uniform float Scale;  slider[-3.0,1.3,3.0]
uniform vec3 Trans; slider[(-5,-5,-5),(0.5,0.5,0.5),(5,5,5)]
uniform vec3 Julia; slider[(-5,-5,-5),(-1,-1,-1),(0,0,0)]
vec4 scale = vec4(Scale, Scale, Scale, abs(Scale)) / MinRad2;
uniform vec3 RotVector; slider[(0,0,0),(1,1,1),(1,1,1)]
uniform float RotAngle; slider[0.00,0,180]

mat3 rot;

void init() {
	 rot = rotationMatrix3(normalize(RotVector), RotAngle);
}

float absScalem1 = abs(Scale - 1.0);
float AbsScaleRaisedTo1mIters = pow(abs(Scale), float(1-Iterations));


float DE2(vec3 pos) {
	vec4 p = vec4(pos,1), p0 = vec4(Julia,1);  // p.w is the distance estimate
	
	for (int i=0; i<Iterations; i++) {
		p.xyz*=rot;
		p.xyz=abs(p.xyz)+Trans;
		float r2 = dot(p.xyz, p.xyz);
		if (i<mColorIterations) orbitTrap = min(orbitTrap, abs(vec4(p.xyz,r2)));
		p *= clamp(max(MinRad2/r2, MinRad2), 0.0, 1.0);  // dp3,div,max.sat,mul
		p = p*scale + p0;
	
	}
	return ((length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters);
}

float DE(vec3 p){
	return  DE1(p) + DE2(p);
}


#preset Default
FOV = 0.5
Eye = -0.538525,3.50432,-2.03126
Target = 0.24092,-1.06038,0.80275
UpLock = false
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
DofCorrect = true
ApertureNbrSides = 5
ApertureRot = 0
ApStarShaped = false
Gamma = 1
ToneMapping = 2
Exposure = 1.11702
Brightness = 1
Contrast = 1
Saturation = 1.25
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0
BloomPow = 8.2353
BloomTaps = 20
BloomStrong = 1
Detail = -3.2
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 322
MaxDistance = 20
Dither = 0.5
NormalBackStep = 1
DetailAO = -0.59577
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 1,1,1,0.64616
AmbiantLight = 1,1,1,1
Reflection = 0.40659,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,1,1,1
LightPos = 0.1124,10,-0.5618
LightSize = 0
LightFallOff = 0
LightGlowRad = 1.4865
LightGlowExp = 1.66665
HardShadow = 0.67949
ShadowSoft = 0
ShadowBlur = 0.03614
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 1,1,1
OrbitStrength = 1
X = 0.5,0.6,0.6,0.08164
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.07084
R = 0.4,0.7,1,1
BackgroundColor = 0.466667,0.52549,0.6
GradientBackground = 0
CycleColors = false
Cycles = 9.51206
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.1
HF_Const = 0
HF_Intensity = 0
HF_Dir = 0,0,1
HF_Offset = 0
HF_Color = 1,1,1,1
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
Size = 1
CSize = 1,1,1
C = 0,0,0
DEoffset = 0.01
Offset = 0,0,0
MnIterations = 2
ColorIterations = 2
MnScale = 3
MnOffset = 1,1,1
Iterations = 17
mColorIterations = 3
MinRad2 = 0.25
Scale = 1.3
Trans = 0.5,0.5,0.5
Julia = -1,-1,-1
RotVector = 1,1,1
RotAngle = 0 Locked
Up = 0.136679,0.912439,0.385712
#endpreset

#preset 02
FOV = 0.7
Eye = 2.15196,-0.166859,0.0796243
Target = -3.16053,0.517346,-0.806327
UpLock = false
FocalPlane = 0.60988
Aperture = 0.03125
InFocusAWidth = 0.51515
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 0.6731
ToneMapping = 5
Exposure = 0.78312
Brightness = 1
Contrast = 1
Saturation = 1.25
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0
BloomPow = 2.4706
BloomTaps = 20
BloomStrong = 1
Detail = -4.2
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 1609
MaxDistance = 5.9
Dither = 1
NormalBackStep = 1
DetailAO = -0.9681
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 0.67778
Specular = 0.34694
SpecularExp = 16
CamLight = 0.709804,0.92549,1,0.76924
AmbiantLight = 1,1,1,0.7234
Reflection = 0.2,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.65098,0.45098,0.8621
LightPos = 2.5842,1.6102,-0.5618
LightSize = 0.21649
LightFallOff = 0
LightGlowRad = 0.6081
LightGlowExp = 0.66665
HardShadow = 1
ShadowSoft = 0
ShadowBlur = 0
perf = true
SSS = false
sss1 = 0.66949
sss2 = 0.32203
BaseColor = 1,1,1
OrbitStrength = 0.16438
X = 0.5,0.6,0.6,0.25252
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.45454
R = 0.4,0.7,1,1
BackgroundColor = 0.368627,0.517647,0.6
GradientBackground = 0.4762
CycleColors = true
Cycles = 9.85402
EnableFloor = true
FloorNormal = 1,0.02564,0
FloorHeight = 1
FloorColor = 0.0392157,0.054902,0.0666667
HF_Fallof = 1.15828
HF_Const = 0
HF_Intensity = 0.2987
HF_Dir = 1,0,0.0097
HF_Offset = 1.6456
HF_Color = 0.670588,0.972549,1,1.98462
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = true
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 0.3
CloudFlatness = 0.8375
CloudTops = 4.5
CloudBase = -6.7088
CloudDensity = 0.93421
CloudRoughness = 1.22034
CloudContrast = 3.2813
CloudColor = 0.733333,0.772549,0.890196
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.917647,0.556863,0.196078
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
MI = 1
Size = 1.998
CSize = 1,0.88496,1
C = 0,0,-1
DEoffset = 0.01
Offset = 0,0,0
MnIterations = 4
ColorIterations = 2
MnScale = 1.92
MnOffset = 0,1.02128,2
Iterations = 17
mColorIterations = 3
MinRad2 = 0.91836
Scale = 1.29468
Trans = 0.5,0.5,0.4028
Julia = -1,-1,-1
RotVector = 0,1,1
RotAngle = 33.4134
Up = 0.159383,0.930075,-0.237444
#endpreset

#preset 03
FOV = 0.4
Eye = -3.08229,0.0539149,0.0390122
Target = 2.34172,-0.123141,-0.117663
UpLock = false
FocalPlane = 3.92045
Aperture = 0
InFocusAWidth = 0.51515
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 1
ToneMapping = 5
Exposure = 1.2
Brightness = 1
Contrast = 1.5
Saturation = 1.25
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0
BloomPow = 5.4118
BloomTaps = 20
BloomStrong = 1
Detail = -3.3
RefineSteps = 3
FudgeFactor = 0.67089
MaxRaySteps = 345
MaxDistance = 5.9
Dither = 0.8
NormalBackStep = 1
DetailAO = -0.5
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 0.67778
Specular = 0.4
SpecularExp = 16
CamLight = 1,1,1,0.43076
AmbiantLight = 1,1,1,0.25532
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,1,1,1
LightPos = 0.1124,2.3596,7.7528
LightSize = 0
LightFallOff = 0
LightGlowRad = 0
LightGlowExp = 1
HardShadow = 0.71795
ShadowSoft = 2
ShadowBlur = 0
perf = true
SSS = false
sss1 = 0.66949
sss2 = 0.32203
BaseColor = 1,1,1
OrbitStrength = 1
X = 0.5,0.6,0.6,0.08164
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.07084
R = 0.4,0.7,1,1
BackgroundColor = 0.6,0.6,0.45
GradientBackground = 0.3
CycleColors = false
Cycles = 9.51206
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 1.15828
HF_Const = 0
HF_Intensity = 0
HF_Dir = 1,0,0.0097
HF_Offset = 1.6456
HF_Color = 0.670588,0.972549,1,1.98462
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = true
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 0.3
CloudFlatness = 0.8375
CloudTops = 4.5
CloudBase = -6.7088
CloudDensity = 0.93421
CloudRoughness = 1.22034
CloudContrast = 3.2813
CloudColor = 0.733333,0.772549,0.890196
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.917647,0.556863,0.196078
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
MI = 4
Size = 1
CSize = 1,1,1
C = 0,0,0
DEoffset = 0.01
Offset = 0,0,0
MnIterations = 2
ColorIterations = 2
MnScale = 3
MnOffset = 1,1,1
Iterations = 12
mColorIterations = 3
MinRad2 = 0.14286
Scale = 1.27254
Trans = 0.5,0.5,0.5
Julia = -1.12535,-0.9649,-1
RotVector = 0,1,1
RotAngle = 90 Locked
Up = 0.0144539,-0.342076,0.886958
#endpreset



#preset 04
FOV = 0.4
Eye = 1.54675,-5.04864,6.27097
Target = -1.02751,0.967433,-1.29076
Gamma = 1.9231
ToneMapping = 2
Exposure = 1
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 1
BloomPow = 5.4118
BloomTaps = 20
BaseColor = 1,1,1
OrbitStrength = 1
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
CycleColors = false
Cycles = 1.1
MI = 10
Size = 2
CSize = 0.30358,1,1
C = 0,0,2
DEoffset = 0.028
Offset = 2,-2,0
MnIterations = 0
ColorIterations = 7
MnScale = 1
MnOffset = 2,2,1
Iterations = 17
mColorIterations = 30
MinRad2 = 1.05892
Scale = 1.56882
Trans = 0,0,0
Julia = -1,-1,-1
RotVector = 1,0,0
RotAngle = 0 Locked
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0.51515
ApertureNbrSides = 7 NotLocked
ApertureRot = 0
ApStarShaped = false
Detail = -2.3
RefineSteps = 3
FudgeFactor = 1
MaxRaySteps = 56
MaxDistance = 66.67
Dither = 0.5
NormalBackStep = 1
DetailAO = -0.1
coneApertureAO = 1
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.32912
AO_pointlight = 0
AoCorrect = 0
Specular = 0.4
SpecularExp = 16
CamLight = 1,1,1,1
AmbiantLight = 1,1,1,0.25532
Reflection = 0,0,0
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,1,1,2.4
LightPos = 2.5842,-10,3.9326
LightSize = 1
LightFallOff = 0
LightGlowRad = 0.8108
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 0
BackgroundColor = 0.6,0.6,0.45
GradientBackground = 0.3
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 1.15828
HF_Const = 0
HF_Intensity = 0
HF_Dir = 1,0,0.0097
HF_Offset = 1.6456
HF_Color = 0.670588,0.972549,1,1.98462
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = true
CloudScale = 0.3
CloudFlatness = 0.8375
CloudTops = 4.5
CloudBase = -6.7088
CloudDensity = 0.93421
CloudRoughness = 1.22034
CloudContrast = 3.2813
CloudColor = 0.733333,0.772549,0.890196
SunLightColor = 0.917647,0.556863,0.196078
Up = 0.490166,0.100952,-0.0865508
#endpreset


#preset 01
FOV = 0.4
Eye = 9.20321,0.0559705,6.37743
Target = 0.839167,-0.0940051,0.89845
UpLock = false
FocalPlane = 9.70306
Aperture = 0
InFocusAWidth = 0.22727
DofCorrect = false
ApertureNbrSides = 5
ApertureRot = 0
ApStarShaped = false
Gamma = 1.0096
ToneMapping = 5
Exposure = 0.70212
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.47058
BloomPow = 4
BloomTaps = 20
BloomStrong = 3.86292
Detail = -2.5
RefineSteps = 4
FudgeFactor = 1
MaxRaySteps = 322
MaxDistance = 100
Dither = 0.76364
NormalBackStep = 0
DetailAO = -0.1
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 0.34043
AO_ambient = 2
AO_camlight = 1.77216
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 4
CamLight = 0.752941,0.901961,1,0.4
AmbiantLight = 0.788235,0.870588,1,0.51064
Reflection = 0.207843,0.294118,0.247059
ReflectionsNumber = 1
SpotGlow = true
SpotLight = 1,0.698039,0.352941,1
LightPos = 7.7528,10,9.1012
LightSize = 0.14433
LightFallOff = 0
LightGlowRad = 2.43245
LightGlowExp = 1.86665
HardShadow = 0.98718
ShadowSoft = 0
ShadowBlur = 0
perf = true
SSS = false
sss1 = 0.66949
sss2 = 0.32203
BaseColor = 1,1,1
OrbitStrength = 0.57534
X = 0.5,0.6,0.6,1
Y = 1,0.6,0,1
Z = 0.8,0.78,1,0.79798
R = 1,0.858824,0.431373,0.0204
BackgroundColor = 0.262745,0.572549,0.6
GradientBackground = 0
CycleColors = false
Cycles = 0.1
EnableFloor = true
FloorNormal = 0,1,0
FloorHeight = -2.748
FloorColor = 0.666667,0.788235,0.898039
HF_Fallof = 0.26362
HF_Const = 0
HF_Intensity = 0.06494
HF_Dir = 0.94174,0,1
HF_Offset = -9.4936
HF_Color = 0.733333,0.882353,0.960784,1.24614
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
MI = 4
Size = 2.38
CSize = 1,1,1
C = -2,0,0
DEoffset = 0.01
Offset = 0,2,0
MnIterations = 2
ColorIterations = 0
MnScale = 4
MnOffset = 2,2,1
Iterations = 11
mColorIterations = 7
MinRad2 = 1.12244
Scale = 1.53492
Trans = 0,0,0
Julia = -1,-1,-1
RotVector = 1,0,1
RotAngle = 0 Locked
Up = 0.00701045,0.906267,-0.0355091
#endpreset


