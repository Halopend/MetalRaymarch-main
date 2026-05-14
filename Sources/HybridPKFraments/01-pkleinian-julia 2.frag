#infoTheli-at's Pseudo Kleinian hybrid with 4D Quaternion Julia

/*
 * Third-Party Formula Attribution
 *
 * Upstream attribution: Theli-at (Pseudo Kleinian + 4D Quaternion Julia hybrid).
 *
 * Licensing status in this repository:
 * - Imported source snippet did not include explicit license text.
 * - Treat as third-party attributed source until upstream license is verified.
 */

//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"



#group 4D Q-Julia

uniform int jIterations;  slider[0,16,100]
uniform float jThreshold; slider[0,10,100]
uniform vec4 jC; slider[(-1,-1,-1,-1),(0.18,0.88,0.24,0.16),(1,1,1,1)]


float DE1(vec3 pos) {
	vec4 p = vec4(pos, 0.0);
	vec4 dp = vec4(1.0, 0.0,0.0,0.0);
	for (int i = 0; i < jIterations; i++) {
		dp = 2.0* vec4(p.x*dp.x-dot(p.yzw, dp.yzw), p.x*dp.yzw+dp.x*p.yzw+cross(p.yzw, dp.yzw));
		p = vec4(p.x*p.x-dot(p.yzw, p.yzw), vec3(2.0*p.x*p.yzw)) + jC;
		float p2 = dot(p,p);
		orbitTrap = min(orbitTrap, abs(vec4(p.xyz,p2)));
		if (p2 > jThreshold) break;
	}
	float r = length(p);
	return  0.5 * r * log(r) / length(dp);
}


#group PseudoKleinian
#define USE_INF_NORM

uniform int MI; slider[0,5,20]
uniform float Size; slider[0,1,2]
uniform vec3 CSize; slider[(0,0,0),(1,1,1),(2,2,2)]
uniform vec3 C; slider[(-2,-2,-2),(0,0,0),(2,2,2)]
uniform float TThickness; slider[0,0.01,2]
uniform float DEoffset; slider[0,0,0.01]
uniform vec3 Offset; slider[(-1,-1,-1),(0,0,0),(1,1,1)]

float RoundBox(vec3 p, vec3 csize, float offset)
{
	vec3 di = abs(p) - csize;
	float k=max(di.x,max(di.y,di.z));
	return abs(k*float(k<0.)+ length(max(di,0.0))-offset);
}


float maxcomp(vec3 a) {
	return 	 max(a.x,max(a.y,a.z));
}

float sdToBox( vec3 p, vec3 b )
{
  vec3  di = abs(p) - b;
  float mc = maxcomp(di);
  return min(mc,length(max(di,0.0)));
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
	
	//return abs(TThickness*abs((p.z-Offset.z)*DE1(p))/DEfactor-DEoffset);
	return abs(0.5*abs((p.z-Offset.z)*DE1(p))/DEfactor-DEoffset);
}

float DE(vec3 p){
	return  Thing2(p);//RoundBox(p, CSize, Offset);
}



#preset Default
FOV = 0.5
Eye = 7.8942,-0.15179,-2.35838
Target = 0.539974,2.21998,-8.70586
FocalPlane = 0.0954846
Aperture = 0
InFocusAWidth = 3.2
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.8
ToneMapping = 5
Exposure = 1
Brightness = 1
Contrast = 1.5
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
BloomIntensity = 0.29412
BloomPow = 7.6471
Detail = -3.46787
FudgeFactor = 0.2
MaxDistance = 166.67
Dither = 0.85455
NormalBackStep = 0
Specular = 0
SpecularExp = 500
CamLight = 0.85098,0.937255,1,0.43076
Reflection = 0.592157,0.454902,0.333333
SpotGlow = true
SpotLight = 1,0.745098,0.560784,0.5172
LightPos = 10,5.7304,-1.6854
LightSize = 0
LightFallOff = 0
LightGlowRad = 0.8784
LightGlowExp = 3.85
HardShadow = 1
BaseColor = 0.686275,0.686275,0.686275
OrbitStrength = 0.17808
BackgroundColor = 0.486275,0.556863,0.6
GradientBackground = 0
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
CloudScale = 1.68885
CloudFlatness = 0
CloudTops = 3
CloudBase = -8.7342
CloudDensity = 0.65789
CloudRoughness = 1.42372
CloudContrast = 0
CloudColor = 0.403922,0.47451,0.545098
SunLightColor = 0.486275,0.513725,0.686275
jIterations = 6
jThreshold = 4
jC = 0,0,0,1
MI = 11
Size = 1
CSize = 1.64602,1.04424,2
C = 0.15624,0,0
TThickness = 0.93182
DEoffset = 0
Offset = 0,0,0
Bloom = false
BloomTaps = 20
RefineSteps = 4
MaxRaySteps = 2000
DetailAO = -1e-05
coneApertureAO = 0.5
maxIterAO = 11
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
AmbiantLight = 1,1,1,0.68086
ReflectionsNumber = 0
ShadowSoft = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
CycleColors = false
Cycles = 1.1
Up = -0.198677,0.109141,0.27097
#endpreset

#preset 1
FOV = 0.5
Eye = 3.76803,7.64003,-3.90201
Target = -4.64902,13.0243,-4.30571
FocalPlane = 0.4
Aperture = 0.00525
InFocusAWidth = 1.62
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 1.39425
ToneMapping = 2
Exposure = 1.75533
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 1.35294
BloomPow = 2.1176
Detail = -3.2
FudgeFactor = 0.79747
MaxDistance = 7
Dither = 0.86364
NormalBackStep = 1
Specular = 0.07143
SpecularExp = 16.176
CamLight = 0.760784,0.870588,1,0.95384
Reflection = 0.2,0,0
SpotGlow = true
SpotLight = 1,0.803922,0.631373,10
LightPos = 9.1012,7.7528,-0.337
LightSize = 0
LightFallOff = 0
LightGlowRad = 1.4865
LightGlowExp = 0.93335
HardShadow = 1
BaseColor = 1,1,1
OrbitStrength = 0.9896
BackgroundColor = 0.313725,0.6,0.541176
GradientBackground = 0.3
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 5
HF_Const = 0
HF_Intensity = 0.07792
HF_Dir = 0.02912,-0.02912,1
HF_Offset = -3.924
HF_Color = 0.439216,0.588235,0.619608,1.01538
HF_Scatter = 0
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 1
HF_CastShadow = false
CloudScale = 0.95556
CloudFlatness = 0.9
CloudTops = 3
CloudBase = -8.7342
CloudDensity = 0.65789
CloudRoughness = 1.42372
CloudContrast = 10
CloudColor = 0.392157,0.415686,0.529412
SunLightColor = 0.486275,0.513725,0.686275
jIterations = 7
jThreshold = 9.091
jC = 0.008,-0.104,0.168,1
MI = 10
Size = 1.03334
CSize = 0.54868,2,2
C = 0,0,0
TThickness = 0.72728
DEoffset = 0.00103
Offset = 0,0,0.26924
Bloom = false
BloomTaps = 2
RefineSteps = 3
MaxRaySteps = 920
DetailAO = -0.1
coneApertureAO = 1
maxIterAO = 14
FudgeAO = 1
AO_ambient = 0.275
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
AmbiantLight = 1,1,1,0.29788
ReflectionsNumber = 4
ShadowSoft = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.59596
Z = 0.8,0.78,1,0.41414
R = 0.4,0.7,1,0.06122
CycleColors = false
Cycles = 3.25689
Up = -0.0162707,0.00102468,0.352907
#endpreset

#preset 2
FOV = 0.6
Eye = 4.83749,11.2762,-3.87054
Target = -1.68957,3.70015,-3.83352
FocalPlane = 0.4
Aperture = 0
InFocusAWidth = 1.62
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 1.6346
ToneMapping = 5
Exposure = 0.63831
Brightness = 0.925
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 1.35294
BloomPow = 2.1176
Detail = -3.5
FudgeFactor = 0.44304
MaxDistance = 7
Dither = 0.83636
NormalBackStep = 1
Specular = 3.2
SpecularExp = 500
CamLight = 0.611765,0.768627,1,0.73846
Reflection = 0.431373,0.501961,0.619608
SpotGlow = true
SpotLight = 1,0.678431,0.396078,2.5862
LightPos = 9.5954,10,0.5618
LightSize = 0.17526
LightFallOff = 0
LightGlowRad = 1.4865
LightGlowExp = 0.93335
HardShadow = 1
BaseColor = 1,1,1
OrbitStrength = 1
BackgroundColor = 0.431373,0.501961,0.619608
GradientBackground = 0.83335
EnableFloor = true
FloorNormal = -0.18,0.06176,1
FloorHeight = -4.037
FloorColor = 0.0392157,0.0823529,0.137255
HF_Fallof = 5
HF_Const = 0
HF_Intensity = 0.07792
HF_Dir = 0.02912,-0.02912,1
HF_Offset = -3.604
HF_Color = 0.313725,0.537255,0.619608,1.01538
HF_Scatter = 0
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 1
HF_CastShadow = false
CloudScale = 0.95556
CloudFlatness = 0.9
CloudTops = 3
CloudBase = -8.7342
CloudDensity = 0.65789
CloudRoughness = 1.42372
CloudContrast = 10
CloudColor = 0.392157,0.415686,0.529412
SunLightColor = 0.486275,0.513725,0.686275
jIterations = 7
jThreshold = 3
jC = 0.536,1,0,0
MI = 7
Size = 0.68334
CSize = 1.09734,1.29204,2
C = -0.03848,0.464,0
TThickness = 1.22728
DEoffset = 0
Offset = -0.03846,0.01924,-2.28
Bloom = true
BloomTaps = 2
RefineSteps = 4
MaxRaySteps = 1034
DetailAO = -0.67018
coneApertureAO = 0.5
maxIterAO = 19
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 1
AmbiantLight = 1,1,1,0.68086
ReflectionsNumber = 2
ShadowSoft = 0
X = 0,0.388235,0.6,1
Y = 0,0.0156863,1,-0.55556
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,1
CycleColors = true
Cycles = 2.1
Up = -0.0405773,0.03665,0.346115
#endpreset


#preset 3
FOV = 0.8
Eye = 1.43322,1.22434,-2.82065
Target = -1.44684,10.6815,-1.31488
FocalPlane = 4.88702
Aperture = 0
InFocusAWidth = 0.65152
ApertureNbrSides = 6
ApertureRot = 32.238
ApStarShaped = false
Gamma = 0.8654
ToneMapping = 2
Exposure = 1.75533
Brightness = 1
Contrast = 1.2
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 1.41176
BloomPow = 5.8824
Detail = -3.3
FudgeFactor = 1
MaxDistance = 12
Dither = 0.86364
NormalBackStep = 1
Specular = 2
SpecularExp = 16
CamLight = 0.670588,0.968627,1,0.58462
Reflection = 1,1,1
SpotGlow = true
SpotLight = 1,0.690196,0.258824,4.6552
LightPos = -4.8314,-3.9326,-2.1348
LightSize = 0
LightFallOff = 0
LightGlowRad = 3.04055
LightGlowExp = 1.6
HardShadow = 1
BaseColor = 1,1,1
OrbitStrength = 1
BackgroundColor = 0,0,0
GradientBackground = 0
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 2.42131
HF_Const = 0
HF_Intensity = 0.03896
HF_Dir = 0,0.0097,1
HF_Offset = -3.1646
HF_Color = 0.458824,0.635294,0.615686,2.90769
HF_Scatter = 10
HF_Anisotropy = 0.317647,0.215686,0.415686
HF_FogIter = 1
HF_CastShadow = true
CloudScale = 1.81112
CloudFlatness = 0.9
CloudTops = -3.75
CloudBase = -7.2152
CloudDensity = 0.86842
CloudRoughness = 1.05084
CloudContrast = 5.9375
CloudColor = 0.298039,0.827451,0.905882
SunLightColor = 0.32549,0.262745,0.184314
jIterations = 7
jThreshold = 10
jC = 0.856,1,-1,0.216
MI = 10
Size = 1.03334
CSize = 0.54868,2,2
C = 0,0.25,0.21876
TThickness = 0.5
DEoffset = 0
Offset = 0,0,2.08
Bloom = true
BloomTaps = 9
RefineSteps = 4
MaxRaySteps = 851
DetailAO = -0.67018
coneApertureAO = 1
maxIterAO = 14
FudgeAO = 1
AO_ambient = 0.275
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0.63333
AmbiantLight = 1,1,1,0.29788
ReflectionsNumber = 0
ShadowSoft = 0
X = 0.5,0.6,0.6,3.4
Y = 1,0.47451,0.47451,-0.75758
Z = 0.8,0.78,1,6.7
R = 0.823529,0.513725,1,-0.12244
CycleColors = true
Cycles = 6.82594
Up = -0.00898858,-0.149307,0.920548
#endpreset

#preset 4
FOV = 0.5
Eye = 8.71177,-2.95935,-2.5878
Target = 2.9547,2.55195,-8.62784
FocalPlane = 0.4
Aperture = 0
InFocusAWidth = 1
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.76925
ToneMapping = 2
Exposure = 1.53192
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
BloomIntensity = 0
BloomPow = 8.2353
Detail = -4.1
FudgeFactor = 1
MaxDistance = 250
Dither = 1
NormalBackStep = 0
Specular = 2
SpecularExp = 4
CamLight = 0.85098,0.937255,1,1
Reflection = 0.121569,0.2,0.117647
SpotGlow = true
SpotLight = 1,0.843137,0.705882,1.4
LightPos = 10,5.955,-1.6854
LightSize = 0.10309
LightFallOff = 0
LightGlowRad = 1
LightGlowExp = 1
HardShadow = 1
BaseColor = 1,1,1
OrbitStrength = 1.28
BackgroundColor = 0.313725,0.6,0.541176
GradientBackground = 0.3
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.0005
HF_Const = 0
HF_Intensity = 0
HF_Dir = 0.02912,-0.02912,1
HF_Offset = -3.1114
HF_Color = 0.431373,0.505882,0.623529,0.83076
HF_Scatter = 0
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 1
HF_CastShadow = true
CloudScale = 1.68885
CloudFlatness = 0
CloudTops = 3
CloudBase = -8.7342
CloudDensity = 0.65789
CloudRoughness = 1.42372
CloudContrast = 0
CloudColor = 0.403922,0.47451,0.545098
SunLightColor = 0.486275,0.513725,0.686275
jIterations = 6
jThreshold = 10
jC = 0,0,0.2,1
MI = 5
Size = 1
CSize = 2,0.86616,2
C = 0.56252,0,0
TThickness = 0.52272
DEoffset = 0
Offset = 0,0,0
Bloom = false
BloomTaps = 18
RefineSteps = 4
MaxRaySteps = 1287
DetailAO = -0.67018
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
AmbiantLight = 1,1,1,0.68086
ReflectionsNumber = 0
ShadowSoft = 5.4
X = 0.5,0.6,0.6,17.8
Y = 0.764706,0.705882,1,113.8
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,0.67346
CycleColors = false
Cycles = 1.67844
Up = -0.0709152,0.219329,0.267722
#endpreset




#preset 5
FOV = 0.5
UseFocalLength = false
FocalLength = 14
FilmGate = 36
Eye = 8.26398,-0.0351617,-0.0139213
Target = -1.18388,3.19475,-0.567072
UpLock = false
Up = 0.0154334,-0.0152443,-0.352617
FocalPlane = 0.4
Aperture = 0
InFocusAWidth = 1
DofCorrect = true
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.76925
ToneMapping = 2
Exposure = 1.53192
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
Bloom = false
BloomIntensity = 1.58824
BloomPow = 8.2353
BloomTaps = 18
BloomStrong = 1
Detail = -3.14678
FudgeFactor = 0.65823
MaxRaySteps = 4000
MaxDistance = 250
Dither = 1
NormalBackStep = 0
AoWeight = 1
AoStep = 20
AoPower = 0
AO = 0,0,0,1
DetailAO = -0.67018
AoCorrect = 0
Specular = 2
SpecularExp = 4
CamLight = 0.85098,0.937255,1,1
CamLightMin = 1
Reflection = 0.121569,0.2,0.117647
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.843137,0.705882,1.4
LightPos = 10,5.955,-1.6854
LightSize = 0.10309
LightFallOff = 0
LightGlowRad = 1
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 5.4
ShadowBlur = 0.02814
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 1,1,1
OrbitStrength = 0
X = 0.5,0.6,0.6,17.8
Y = 0.764706,0.705882,1,113.8
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,0.67346
BackgroundColor = 0.313725,0.6,0.541176
GradientBackground = 0.3
Vignette = false
Horizontal = false
Vertical = false
GradientSkyOffset = 0.67
ColorfulBg = 0,0,0
GrOffet = 0
CycleColors = false
Cycles = 1.67844
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 0.0005
HF_Const = 0
HF_Intensity = 0
HF_Dir = 0.02912,-0.02912,1
HF_Offset = -3.1114
HF_Color = 0.431373,0.505882,0.623529,0.83076
GodRays = false
HF_Scatter = 23
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 16
HF_CastShadow = true
ElableClouds = false
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
SunLightColor = 0.486275,0.513725,0.686275
jIterations = 4
jThreshold = 100
jC = 2.1,0,0,1
MI = 7
Size = 1.4
CSize = 2,0,0
C = 0.34376,0,0
TThickness = 0.31818
DEoffset = 0
Offset = 0,0,0
#endpreset

#preset title
FOV = 0.5
Eye = 7.8942,-0.15179,-2.35838
Target = 0.544716,2.77392,-8.47604
FocalPlane = 2.54499
Aperture = 0.08334
InFocusAWidth = 0.25758
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
BloomIntensity = 0.7
BloomPow = 3
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
jIterations = 6
jThreshold = 4
jC = 0,0,0,1
MI = 11
Size = 1
CSize = 1.64602,1.04424,2
C = 0.15624,0,0
TThickness = 0.93182
DEoffset = 0
Offset = 0,0,0
UpLock = false
DofCorrect = true
Bloom = true
BloomTaps = 20
BloomStrong = 1
perf = false
SSS = false
sss1 = 0.67797
sss2 = 0
ShadowSoft = 3.1998
ShadowBlur = 0.05719
Up = -0.576389,0.154867,0.766511
#endpreset


#preset title_2
FOV = 0.6
Eye = -2.82328,-2.60288,-3.18684
Target = 2.55892,5.63161,-1.39103
FocalPlane = 2.44971
Aperture = 0.11979
InFocusAWidth = 1
ApertureNbrSides = 8
ApertureRot = 0
ApStarShaped = false
Gamma = 0.3846
ToneMapping = 2
Exposure = 1.75533
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 1.05882
BloomPow = 1.8824
Detail = -3.3
FudgeFactor = 1.06
MaxRaySteps = 491
MaxDistance = 17
Dither = 0.86364
NormalBackStep = 0
Specular = 0.69388
SpecularExp = 16
CamLight = 0.760784,0.870588,1,1.53846
Reflection = 0.72549,0.905882,1
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.737255,0.470588,3.2759
LightPos = -5.278,0.2252,-0.0454
LightSize = 0.10309
LightFallOff = 0
LightGlowRad = 1
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 0
BaseColor = 1,1,1
OrbitStrength = 1
X = 0.5,0.6,0.6,-1
Y = 0.584314,0.360784,0.00392157,2.26
Z = 1,0.705882,0.294118,-0.37374
R = 0.305882,1,0.270588,0.22448
BackgroundColor = 0.301961,0.654902,0.67451
GradientBackground = 0.7143
CycleColors = false
Cycles = 1.1
EnableFloor = false
FloorNormal = 0,-0.05128,1
FloorHeight = -4.155
FloorColor = 0,0,0
HF_Fallof = 0.1
HF_Const = 0
HF_Intensity = 0.11688
HF_Dir = -1,0.0097,1
HF_Offset = -1.1392
HF_Color = 0.498039,0.576471,0.713725,1.3
HF_Scatter = 23
HF_Anisotropy = 0.0705882,0.521569,0.647059
HF_FogIter = 16
HF_CastShadow = true
CloudScale = 1.19999
CloudTops = -0.5
CloudBase = -6.7088
CloudDensity = 0.32895
CloudRoughness = 0.64406
CloudContrast = 10
CloudColor = 0.345098,0.67451,0.772549
SunLightColor = 0.686275,0.364706,0
MI = 10
Size = 1.03334
CSize = 0.54868,2,2
C = 0,0,0
TThickness = 0
DEoffset = 0
Offset = 0,0,0
UpLock = false
DofCorrect = true
Bloom = true
BloomTaps = 20
BloomStrong = 1
RefineSteps = 4
DetailAO = -0.67018
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 1
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 0.58889
AmbiantLight = 1,1,1,1
ShadowBlur = 0.0002
perf = true
SSS = false
sss1 = 0.1
sss2 = 0.5
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudFlatness = 0.525
CloudColor2 = 0.07,0.17,0.24
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
jIterations = 7
jThreshold = 10
jC = 0.856,1,-1,0.456
Up = -0.0287926,-0.056807,0.346776
#endpreset
