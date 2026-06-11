
//#define providesInit
#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "ColorPalette.frag"
#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

uniform float f1; slider[0,1,2]
uniform float f2; slider[0,1,2]
uniform float f3; slider[0,10,20]

uniform vec3 RotVec; slider[(-1,-1,-1),(0,0,1),(1,1,1)]
uniform float RotAng; slider[0.00,0,360]
uniform vec3 Move; slider[(-5.0,-5.0,-5.0),(0.0,0.0,0.0),(5.0,5.0,5.0)];

uniform int ColorIterations;  slider[0,2,20]

mat3 rotFloor;

float DE(vec3 pos) {
rotFloor = rotationMatrix3(normalize(RotVec), RotAng);

pos=rotFloor*pos;
pos=pos+Move;
return (length(pos)-f1)+sin(pos.x*pos.y*pos.z*100.0*f2)/f3;
}


float Coloring(vec3 p) {
	float expsmooth=0.0;
	float r1 = 0.0, r2 = 0.0;
	rotFloor = rotationMatrix3(normalize(RotVec), RotAng);
	p=rotFloor*p;
	p=p+Move;
	for (int i=0; i<ColorIterations; i++) {
		float pos;
		r1 = r2;
		r2 = dot(p, p);
		
		pos= length(p)-f1+sin(p.x*p.y*p.z*100.0*f2)/f3;
		r1 = r2;
		r2 = dot(pos, pos);
		expsmooth+=exp(-1.0/abs(r1-r2));	
	}
	return expsmooth;
}



#preset Dedault
FOV = 0.4
Eye = 0.0548466,-5.109,0.32708
Target = -0.0883958,-2.12046,0.107856
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
ApertureNbrSides = 5 NotLocked
ApertureRot = 0
ApStarShaped = false NotLocked
Gamma = 1
ToneMapping = 2
Exposure = 1
Brightness = 1
Contrast = 2.08335
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 0
BloomPow = 2
BloomTaps = 4
Detail = -3
RefineSteps = 4
FudgeFactor = 0.21795
MaxRaySteps = 721
MaxDistance = 84.75
Dither = 1
NormalBackStep = 1
DetailAO = -0.30107
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.61538
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 1,1,1,1
AmbiantLight = 1,1,1,1
Reflection = 1,1,1
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,1,1,1
LightPos = 0.2272,-3.8636,3.6364
LightSize = 0.19792
LightFallOff = 0
LightGlowRad = 2.26025
LightGlowExp = 3.04055
HardShadow = 1
ShadowSoft = 20
BaseColor = 0.47451,0.47451,0.47451
OrbitStrength = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.6,0.6,0.6
GradientBackground = 0.3
CycleColors = false
Cycles = 1.1
EnableFloor = true
FloorNormal = 0,0,1
FloorHeight = -1.1194
FloorColor = 0.423529,0.423529,0.423529
HF_Fallof = 0.26642
HF_Const = 0
HF_Intensity = 0.09211
HF_Dir = 0,0,1
HF_Offset = -2.0512
HF_Color = 0.686275,0.827451,1,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = true NotLocked
Clouds_Dir = 0,-0.06024,1 NotLocked
CloudScale = 4.18375 NotLocked
CloudFlatness = 0.31344 NotLocked
CloudTops = 9.2406 NotLocked
CloudBase = -0.2564 NotLocked
CloudDensity = 1 NotLocked
CloudRoughness = 1.7931 NotLocked
CloudContrast = 6.9841 NotLocked
CloudColor = 0.901961,0.945098,0.968627 NotLocked
CloudColor2 = 0.415686,0.501961,0.745098 NotLocked
SunLightColor = 0.698039,0.564706,0.431373 NotLocked
Cloudvar1 = 0.99 NotLocked
Cloudvar2 = 20 NotLocked
CloudIter = 5 NotLocked
CloudBgMix = 0.27711 NotLocked
f1 = 1
f2 = 1
f3 = 10
RTerVec = 0,1,1
RTerAng = 0
MovTer = 0,0,0
Up = -0.00998978,0.0726784,0.997305
#endpreset


#preset 1
Color1 = 0.34902,0.94902,1
Color2 = 0.243137,0.423529,0.541176
Color3 = 0.180392,0.290196,0.360784
ColorDensity = 0.5733
ColorOffset = 0.3896
FOV = 0.4
Eye = 0.0166485,-4.31205,0.26862
Target = -0.0528325,-1.32085,0.0499408
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
ApertureNbrSides = 5 NotLocked
ApertureRot = 0
ApStarShaped = false NotLocked
Gamma = 1
ToneMapping = 2
Exposure = 1
Brightness = 1
Contrast = 2.08335
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = false
BloomIntensity = 0.29412
BloomPow = 7.4118
Detail = -3
RefineSteps = 4
FudgeFactor = 0.21795
MaxRaySteps = 721
MaxDistance = 84.75
Dither = 0.81818
NormalBackStep = 1
DetailAO = -1.5638
coneApertureAO = 1
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.61538
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 1,1,1,1
AmbiantLight = 1,1,1,1
Reflection = 0.454902,0.454902,0.454902
ReflectionsNumber = 2
SpotGlow = true
SpotLight = 1,1,1,1
LightPos = 0.2272,-3.8636,3.6364
LightSize = 0.19792
LightFallOff = 0
LightGlowRad = 2.26025
LightGlowExp = 3.04055
HardShadow = 1
ShadowSoft = 0.2666
ShadowBlur = 0.24096
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.47451,0.47451,0.47451
OrbitStrength = 0.46575
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.6,0.6,0.6
GradientBackground = 1.07145
CycleColors = false
Cycles = 1.1
EnableFloor = true
FloorNormal = 0,0,1
FloorHeight = -1.1194
FloorColor = 0.356863,0.356863,0.356863
HF_Fallof = 0.26642
HF_Const = 0
HF_Intensity = 0.09211
HF_Dir = 0,0,1
HF_Offset = -2.0512
HF_Color = 0.737255,0.87451,1,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = true NotLocked
Clouds_Dir = 0,-0.06024,1 NotLocked
CloudScale = 4.18375 NotLocked
CloudFlatness = 0.41344 NotLocked
CloudTops = 9.2406 NotLocked
CloudBase = 0.0436 NotLocked
CloudDensity = 1 NotLocked
CloudRoughness = 1.7931 NotLocked
CloudContrast = 7.1875 NotLocked
CloudColor = 0.901961,0.945098,0.968627 NotLocked
CloudColor2 = 0.415686,0.501961,0.745098 NotLocked
SunLightColor = 0.698039,0.564706,0.431373 NotLocked
Cloudvar1 = 0.57778 NotLocked
Cloudvar2 = 16.6072 NotLocked
CloudIter = 6 NotLocked
CloudBgMix = 0.30952 NotLocked
f1 = 1
f2 = 1
f3 = 10
ColorIterations = 9
UpLock = false
DofCorrect = true
BloomTaps = 30
BloomStrong = 1
RotVec = 0,0,1
RotAng = 0
Move = 0,0,0
Up = -0.00998978,0.0726784,0.997305
#endpreset


#preset 2
Color1 = 0.784314,0.572549,0.4
Color2 = 0.243137,0.423529,0.541176
Color3 = 0.180392,0.290196,0.360784
ColorDensity = 3.75
ColorOffset = 5.3247
FOV = 0.4
Eye = -0.00692984,-2.2195,-0.0840101
Target = 0.0182871,0.778427,0.0244
UpLock = false
FocalPlane = 1
Aperture = 0
InFocusAWidth = 0
DofCorrect = true
ApertureNbrSides = 5
ApertureRot = 0
ApStarShaped = false
Gamma = 1.39425
ToneMapping = 5
Exposure = 0.63831
Brightness = 1
Contrast = 1.08245
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.44118
BloomPow = 2.3529
BloomTaps = 30
BloomStrong = 1
Detail = -3
RefineSteps = 4
FudgeFactor = 0.21795
MaxRaySteps = 721
MaxDistance = 84.75
Dither = 0.81818
NormalBackStep = 1
DetailAO = -1.5638
coneApertureAO = 1
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.61538
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 16
CamLight = 1,1,1,0.55384
AmbiantLight = 1,1,1,0.97872
Reflection = 0.454902,0.454902,0.454902
ReflectionsNumber = 2
SpotGlow = true
SpotLight = 1,1,1,1
LightPos = 0.2272,-3.8636,3.6364
LightSize = 0.19792
LightFallOff = 0
LightGlowRad = 2.26025
LightGlowExp = 3.04055
HardShadow = 1
ShadowSoft = 0.2666
ShadowBlur = 0.24096
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.47451,0.47451,0.47451
OrbitStrength = 0.46575
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.6,0.6,0.6
GradientBackground = 1.07145
CycleColors = false
Cycles = 1.1
EnableFloor = true
FloorNormal = 0,0,1
FloorHeight = -1.1194
FloorColor = 0.356863,0.356863,0.356863
HF_Fallof = 0.26642
HF_Const = 0
HF_Intensity = 0.09211
HF_Dir = 0,0,1
HF_Offset = -2.0512
HF_Color = 0.737255,0.87451,1,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = true NotLocked
Clouds_Dir = 0,-0.06024,1 NotLocked
CloudScale = 4.18375 NotLocked
CloudFlatness = 0.41344 NotLocked
CloudTops = 9.2406 NotLocked
CloudBase = 0.0436 NotLocked
CloudDensity = 1 NotLocked
CloudRoughness = 1.7931 NotLocked
CloudContrast = 7.1875 NotLocked
CloudColor = 0.901961,0.945098,0.968627 NotLocked
CloudColor2 = 0.415686,0.501961,0.745098 NotLocked
SunLightColor = 0.698039,0.564706,0.431373 NotLocked
Cloudvar1 = 0.57778 NotLocked
Cloudvar2 = 16.6072 NotLocked
CloudIter = 6 NotLocked
CloudBgMix = 0.30952 NotLocked
f1 = 0.69018
f2 = 2
f3 = 16.748
RotVec = 0,0.41176,1
RotAng = 94.9464
Move = 0,0.0459,0
ColorIterations = 9
Up = -0.00660885,-0.0360818,0.999327
#endpreset
