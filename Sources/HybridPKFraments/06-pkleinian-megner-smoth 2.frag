#info Pseudo Kleinian hybrid with Smooth Menger 

/*
 * Third-Party Formula Attribution
 *
 * Upstream attribution: Pseudo Kleinian + smooth Menger hybrid
 * (community Fragmentarium source).
 *
 * Licensing status in this repository:
 * - Imported source snippet did not include explicit license text.
 * - Treat as third-party attributed source until upstream license is verified.
 */

#define providesInit
//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"

#group PseudoKleinian
uniform int MI; slider[0,5,20]
uniform float Size; slider[0,1,2]
uniform vec3 CSize; slider[(0,0,0),(1,1,1),(2,2,2)]
uniform vec3 C; slider[(-2,-2,-2),(0,0,0),(2,2,2)]
uniform float DEoffset; slider[0,0,0.01]
uniform vec3 Offset; slider[(-1,-1,-1),(0,0,0),(1,1,1)]

uniform float Scale; slider[0.00,3.0,4.00]
uniform float s; slider[0.000,0.005,0.100]
uniform bool Sphere;checkbox[false]
uniform vec3 RotVector; slider[(0,0,0),(1,1,1),(1,1,1)]
uniform float RotAngle; slider[0.00,0,180]

mat3 rot;

void init() {
	rot = rotationMatrix3(normalize(RotVector), RotAngle);
}

uniform int Iterations;  slider[0,8,100]
uniform int ColorIterations;  slider[0,8,100]

vec3 convert3 (vec3 z) {
	vec3 z2=normalize(abs(z));
	float ang1=abs(atan(z2.y/z2.z));  
	float r2=sqrt(z2.z*z2.z+z2.y*z2.y);
	float ang2=abs(atan(r2/z2.x));
	if (ang1<.7854) {ang1=1./cos(ang1);}  else {ang1=1./sin(ang1);}
	if (ang2<.7854) {ang2=1./cos(ang2);}  else {ang2=1./sin(ang2);}
	z.yz*=ang1;
	z.xyz*=ang2;
	return z;
}

float Menger(vec3 z)
{
	float t=9999.0;
	float sc=Scale;
	float sc1=sc-1.0;
	float sc2=sc1/sc;
	vec3 C=vec3(1.0,1.0,.5);
	float w=1.;
	int n = 0;
	if(Sphere) {z=convert3(z);}
	while (n < Iterations) {
		z = vec3(sqrt(z.x*z.x+s),sqrt(z.y*z.y+s),sqrt(z.z*z.z+s));
		z = rot *z;
		t=z.x-z.y;  t= .5*(t-sqrt(t*t+s));
		z.x=z.x-t;	z.y=z.y+t;
		t=z.x-z.z; t= 0.5*(t-sqrt(t*t+s));
  		z.x=z.x-t;	 z.z= z.z+t;
		t=z.y-z.z;  t= 0.5*(t-sqrt(t*t+s));
  		z.y=z.y-t;  z.z= z.z+t;
		z.z = z.z-C.z*sc2;
		z.z=-sqrt(z.z*z.z+s);
		z.z=z.z+C.z*sc2;
		z.x=sc*z.x-C.x*sc1;
		z.y=sc*z.y-C.y*sc1;
		z.z=sc*z.z;
		w=w*sc;
		if (n<ColorIterations) orbitTrap = min(orbitTrap, (vec4(abs(z),dot(z,z))));
		n++;
	}
	return abs(length(z)-0.0 ) /w;
	//return abs(length(z)-0.0 ) * pow(Scale, float(-n));
}

float Thing2(vec3 p){
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
	return abs(0.5*Menger(p*Offset)/DEfactor-DEoffset);
}

float DE(vec3 p){
	return  Thing2(p);
}



#preset Default
FOV = 0.47058
Eye = 3.62451,1.6708,3.40656
Target = -2.19623,-6.07156,4.90427
UpLock = false
FocalPlane = 0.995001
Aperture = 0
InFocusAWidth = 3.5
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 1
ToneMapping = 5
Exposure = 1
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0.25
BloomPow = 2
BloomTaps = 4
BloomStrong = 1
Detail = -3.9
RefineSteps = 1
FudgeFactor = 0.60759
MaxRaySteps = 350
MaxDistance = 10
Dither = 0.78182
NormalBackStep = 1
DetailAO = -1.04258
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.84616
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 10
CamLight = 0.733333,0.917647,1,0.3125
AmbiantLight = 1,1,1,0.26086
Reflection = 0.615686,0.419608,0.0313725
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.839216,0.701961,1
LightPos = 3.0338,1.0112,2.809
LightSize = 0
LightFallOff = 0
LightGlowRad = 0.68495
LightGlowExp = 1.8243
HardShadow = 1
ShadowSoft = 0
ShadowBlur = 0
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.541176,0.701961,0.611765
OrbitStrength = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.709804,0.541176,0.329412
GradientBackground = 0
CycleColors = false
Cycles = 1.1
EnableFloor = false
FloorNormal = 0,-0.00186,1
FloorHeight = 3.8244
FloorColor = 0.654902,0.666667,0.776471
HF_Fallof = 5
HF_Const = 0
HF_Intensity = 0.85714
HF_Dir = 0,0,-1
HF_Offset = -3.8462
HF_Color = 0.666667,0.701961,0.839216,1
HF_Scatter = 0
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = true NotLocked
Clouds_Dir = -0.0238,0,1 NotLocked
CloudScale = 0.71113
CloudFlatness = 0.1125 NotLocked
CloudTops = 10
CloudBase = 1.6118
CloudDensity = 0.94737
CloudRoughness = 0.91526
CloudContrast = 1.25
CloudColor = 0.615686,0.662745,0.729412
CloudColor2 = 0.298039,0.254902,0.541176 NotLocked
SunLightColor = 0.360784,0.439216,0.694118
Cloudvar1 = 0 NotLocked
Cloudvar2 = 1 NotLocked
CloudIter = 5 NotLocked
CloudBgMix = 0.59524 NotLocked
MI = 4
Size = 1.38334
CSize = 1,1,0.95576
C = -1.5,0,0
DEoffset = 0
Offset = 1,0.21154,1
Scale = 3
s = 0.00821
Sphere = true
RotVector = 1,0,0
RotAngle = 0
Iterations = 8
ColorIterations = 8
Up = -0.22346,-0.0104604,-0.922534
#endpreset


#preset 1
FOV = 0.47058
Eye = 2.41342,2.82107,3.33356
Target = 5.16299,-6.56148,2.6436
UpLock = false
FocalPlane = 0.995001
Aperture = 0
InFocusAWidth = 3.5
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 1.8173
ToneMapping = 5
Exposure = 0.92553
Brightness = 1
Contrast = 1
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
BloomIntensity = 0.5
BloomPow = 1
BloomTaps = 20
BloomStrong = 1
Detail = -3.9
RefineSteps = 4
FudgeFactor = 0.60759
MaxRaySteps = 529
MaxDistance = 266.67
Dither = 0.78182
NormalBackStep = 1
DetailAO = -1.04258
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
Specular = 0
SpecularExp = 10
CamLight = 0.733333,0.917647,1,0.4923
AmbiantLight = 1,1,1,0
Reflection = 0.615686,0.419608,0.0313725
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.839216,0.701961,0.9
LightPos = 3.1818,0.6818,2.0454
LightSize = 0.04124
LightFallOff = 0
LightGlowRad = 0.41095
LightGlowExp = 0.8
HardShadow = 1
ShadowSoft = 0
ShadowBlur = 0
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.541176,0.701961,0.611765
OrbitStrength = 0
X = 0.5,0.6,0.6,0.7
Y = 1,0.6,0,0.4
Z = 0.8,0.78,1,0.5
R = 0.4,0.7,1,0.12
BackgroundColor = 0.396078,0.505882,0.709804
GradientBackground = 0
CycleColors = false
Cycles = 1.1
EnableFloor = true
FloorNormal = 0,-0.00186,1
FloorHeight = 3.6
FloorColor = 0.654902,0.666667,0.776471
HF_Fallof = 5
HF_Const = 0
HF_Intensity = 0.22078
HF_Dir = 0,0,-1
HF_Offset = -3.6156
HF_Color = 0.666667,0.701961,0.839216,1.38462
HF_Scatter = 5.7692
HF_Anisotropy = 0,0,0
HF_FogIter = 1
HF_CastShadow = true
EnCloudsDir = true NotLocked
Clouds_Dir = -0.0238,0,1 NotLocked
CloudScale = 1.07782
CloudFlatness = 0.64706 NotLocked
CloudTops = 7
CloudBase = -10
CloudDensity = 0.90789
CloudRoughness = 1.69492
CloudContrast = 2.9688
CloudColor = 0.580392,0.713725,0.74902
CloudColor2 = 0.298039,0.254902,0.541176 NotLocked
SunLightColor = 0.694118,0.470588,0.215686
Cloudvar1 = 0 NotLocked
Cloudvar2 = 1 NotLocked
CloudIter = 5 NotLocked
CloudBgMix = 0.59524 NotLocked
MI = 5
Size = 1.38334
CSize = 1,0,1
C = -1.5,0,0
DEoffset = 0.00082
Offset = 0.46276,0.21154,1
Scale = 3
s = 0.00821
Sphere = true
RotVector = 1,0,0
RotAngle = 0
Iterations = 7
ColorIterations = 8
Up = -0.00273032,0.0371154,-0.515601
#endpreset





#preset 2
FOV = 0.53782
Eye = 10.6226,2.62919,3.14435
Target = 6.38415,-5.15231,7.3339
UpLock = false
FocalPlane = 0.995001
Aperture = 0
InFocusAWidth = 3.5
DofCorrect = true
ApertureNbrSides = 7
ApertureRot = 0
ApStarShaped = false
Gamma = 1.6796
ToneMapping = 3
Exposure = 0.64515
Brightness = 1
Contrast = 1.77085
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2
Bloom = true
BloomIntensity = 1.25
BloomPow = 3
BloomTaps = 10
BloomStrong = 1
Detail = -3
RefineSteps = 2
FudgeFactor = 0.88608
MaxRaySteps = 529
MaxDistance = 266.67
Dither = 0.95455
NormalBackStep = 1
DetailAO = -0.15057
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0.78482
AO_pointlight = 0
AoCorrect = 0
Specular = 1
SpecularExp = 7
CamLight = 0.733333,0.917647,1,0.75
AmbiantLight = 1,1,1,0.56522
Reflection = 0.866667,0.592157,0.207843
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.839216,0.701961,0.9
LightPos = 10,2.2728,2.9546
LightSize = 0
LightFallOff = 0
LightGlowRad = 0.68495
LightGlowExp = 0.8784
HardShadow = 1
ShadowSoft = 0
ShadowBlur = 0
perf = false
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.541176,0.701961,0.611765
OrbitStrength = 1
X = 0.5,0.6,0.6,0.21212
Y = 0.635294,0.745098,1,1
Z = 0.8,0.78,1,0.31314
R = 0.615686,1,0.54902,0.34694
BackgroundColor = 0.709804,0.541176,0.329412
GradientBackground = 0
CycleColors = false
Cycles = 9.88622
EnableFloor = false
FloorNormal = 0,-0.056,1
FloorHeight = 3.125
FloorColor = 0.482353,0.545098,0.521569
HF_Fallof = 0.79827
HF_Const = 0
HF_Intensity = 0.09211
HF_Dir = 1,-1,1
HF_Offset = 10
HF_Color = 0.498039,0.654902,0.843137,1
HF_Scatter = 0
HF_Anisotropy = 0.384314,0.603922,0.705882
HF_FogIter = 1
HF_CastShadow = true
EnCloudsDir = true NotLocked
Clouds_Dir = -0.0238,0,1 NotLocked
CloudScale = 0.71113
CloudFlatness = 0.1125 NotLocked
CloudTops = 10
CloudBase = 1.6118
CloudDensity = 0.94737
CloudRoughness = 0.91526
CloudContrast = 1.25
CloudColor = 0.615686,0.662745,0.729412
CloudColor2 = 0.298039,0.254902,0.541176 NotLocked
SunLightColor = 0.360784,0.439216,0.694118
Cloudvar1 = 0 NotLocked
Cloudvar2 = 1 NotLocked
CloudIter = 5 NotLocked
CloudBgMix = 0.59524 NotLocked
MI = 7
Size = 2
CSize = 1,1,0.92036
C = 1,0,1
DEoffset = 0
Offset = 1,-0.01924,-1
Scale = 3
s = 0.02015
Sphere = true
RotVector = 1,0,0
RotAngle = 0
Iterations = 6
ColorIterations = 8
Up = -0.262017,-0.338825,-0.894393
#endpreset

#preset 3
FOV = 0.47058
Eye = 5.4163,-0.683752,-5.38485
Target = -4.12538,1.55589,-5.47952
FocalPlane = 0.995001
Aperture = 0
InFocusAWidth = 3.5
ApertureNbrSides = 7 NotLocked
ApertureRot = 0
ApStarShaped = false
Gamma = 1.58655
ToneMapping = 5
Exposure = 0.89361
Brightness = 1
Contrast = 1.2
Saturation = 1
GaussianWeight = 1
AntiAliasScale = 2.5
Bloom = true
BloomIntensity = 0.5
BloomPow = 2
BloomTaps = 20
Detail = -3.3
RefineSteps = 2
FudgeFactor = 0.60759
MaxRaySteps = 529
MaxDistance = 13
Dither = 0.78182
NormalBackStep = 1
DetailAO = -1.04258
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
Specular = 2
SpecularExp = 9
CamLight = 0.756863,0.705882,1,0.8
AmbiantLight = 1,1,1,0.93618
Reflection = 0.607843,0.796078,0.698039
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.67451,0.439216,1.2
LightPos = 0.1124,-0.7866,-5.5056
LightSize = 0.24742
LightFallOff = 0
LightGlowRad = 2.2973
LightGlowExp = 3
HardShadow = 0.5
ShadowSoft = 1
BaseColor = 0.537255,0.701961,0.611765
OrbitStrength = 0.73973
X = 0.5,0.6,0.6,0.21212
Y = 0.635294,0.745098,1,1
Z = 0.8,0.78,1,0.31314
R = 0.615686,1,0.54902,0.34694
BackgroundColor = 0.709804,0.541176,0.329412
GradientBackground = 0
CycleColors = false
Cycles = 9.88622
EnableFloor = true
FloorNormal = 0,-0.00186,1
FloorHeight = 3.8244
FloorColor = 0.670588,0.623529,0.862745
HF_Fallof = 0.57939
HF_Const = 0
HF_Intensity = 0.24675
HF_Dir = -0.18446,-0.61166,0.08738
HF_Offset = -1.1392
HF_Color = 0.556863,0.537255,0.843137,0.156
HF_Scatter = 26
HF_Anisotropy = 0,0,0
HF_FogIter = 10
HF_CastShadow = true
CloudScale = 0.71113
CloudFlatness = 0
CloudTops = 2.75
CloudBase = 1.3924
CloudDensity = 0.60526
CloudRoughness = 1.49152
CloudContrast = 1.5625
CloudColor = 0.384314,0.380392,0.34902
SunLightColor = 0.509804,0.368627,0.301961
MI = 7
Size = 1.38334
CSize = 1.07964,1.29204,0.97346
C = -2,-2,0.43752
DEoffset = 0
Offset = -0.42308,0.21154,1
Scale = 3
s = 0.00149
Sphere = true
RotVector = 1,0,0.31522
RotAngle = 65.061
Iterations = 6
ColorIterations = 8
Up = 0.0221166,0.052909,-0.977448
#endpreset