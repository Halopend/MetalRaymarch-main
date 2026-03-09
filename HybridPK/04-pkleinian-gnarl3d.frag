#info Pseudo Kleinian hybrid with Gnarl3D 

//#define USE_IQ_CLOUDS
#define KN_VOLUMETRIC
#define USE_EIFFIE_SHADOW
#define MULTI_SAMPLE_AO

#include "MathUtils.frag"
//#include "DE-Kn2cr10.frag"
#include "DE-Kn2cr11.frag"


uniform int GI; slider[0,16,50]
uniform float GPow; slider[1,1,5]
uniform float Gparam; slider[-1,0,1]
uniform vec2 Gnarl; slider[(0,0),(0,0),(1,1)]

float Mag(vec3 pos) {
vec3 z=pos;
int i=0;
float Xold = z.x;
float Yold = z.y;
float xn = 0.0;
float yn = 0.0; 
for (i=0; i<GI; i++) {
xn = z.x - (0.1+Gnarl.x/10)* sin(z.y + 5*sin(2*z.y-0.2*z.x));
yn = z.y - (0.1+Gnarl.y/10)* sin(z.x + 5*sin(2*z.x-0.2*z.y)); 
z.x= xn; z.y= yn;
}
xn = Xold-z.x;
yn = Yold-z.y;
float mag = 1.5+Gparam + xn*xn+ yn*yn;
mag = log(mag*GPow); //smooth
return z.z-mag;
}


#define USE_INF_NORM

uniform int MI; slider[0,5,20]

// Bailout
//uniform float Bailout; slider[0,20,1000]

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
	return abs(TThickness*abs((p.z-Offset.z)*Mag(p))/DEfactor-DEoffset);
}

float DE(vec3 p){
	//return  Thing2(p);//RoundBox(p, CSize, Offset);
	return  Thing2(p);
}






#preset Default
FOV = 0.5
Eye = 0.685314,-13.9742,4.28915
Target = 8.63082,-7.90366,4.15614
UpLock = false
FocalPlane = 1.69974
Aperture = 0.06771
InFocusAWidth = 0.56061
DofCorrect = true
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.96155
ToneMapping = 4
Exposure = 0.95745
Brightness = 1
Contrast = 2.1134
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
BloomIntensity = 0
BloomPow = 8.2353
BloomTaps = 18
BloomStrong = 1
Detail = -3.7
RefineSteps = 4
FudgeFactor = 0.65823
MaxRaySteps = 2000
MaxDistance = 250
Dither = 0.81818
NormalBackStep = 0
DetailAO = -0.07448
coneApertureAO = 1
maxIterAO = 18
FudgeAO = 1
AO_ambient = 2
AO_camlight = 1
AO_pointlight = 0.4054
AoCorrect = 0
Specular = 0
SpecularExp = 4
CamLight = 0.690196,0.894118,1,0.4
AmbiantLight = 0.768627,0.894118,1,0.46808
Reflection = 0.121569,0.2,0.117647
ReflectionsNumber = 0
SpotGlow = true
SpotLight = 1,0.878431,0.752941,3.4
LightPos = 0.7866,-13.02,4.382
LightSize = 0.10309
LightFallOff = 0
LightGlowRad = 0.54055
LightGlowExp = 3.33335
HardShadow = 1
ShadowSoft = 2.6666
ShadowBlur = 0.06024
perf = true
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.729412,0.729412,0.729412
OrbitStrength = 0
X = 0.5,0.6,0.6,0.9596
Y = 0.764706,0.705882,1,0.55556
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,1
BackgroundColor = 0,0,0
GradientBackground = 0.3
CycleColors = false
Cycles = 2.62545
EnableFloor = false
FloorNormal = -0.5641,1,0
FloorHeight = -8.3
FloorColor = 1,1,1
HF_Fallof = 0.36886
HF_Const = 0.08696
HF_Intensity = 0
HF_Dir = 0.12622,0.2233,1
HF_Offset = -4.9368
HF_Color = 0.690196,0.929412,1,3
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
GI = 5
GPow = 1.28572
Gparam = 0.7551
Gnarl = 0.21053,0.78947
MI = 9
Size = 1.48334
CSize = 2,1.20354,0.88496
C = 2,0,0
TThickness = 0.3409
DEoffset = 0.01
Offset = 0.23076,0,0
Up = 0.0227319,-0.00902317,0.946086
#endpreset


#preset 1
FOV = 0.7
Eye = 3.29503,6.21996,7.7804
Target = 13.2535,5.70423,7.02957
UpLock = false
FocalPlane = 2.54957
Aperture = 0.04
InFocusAWidth = 0.33333
DofCorrect = true
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.76925
ToneMapping = 5
Exposure = 0.79788
Brightness = 1
Contrast = 2
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
Bloom = true
BloomIntensity = 0.2647
BloomPow = 3.7647
BloomTaps = 20
BloomStrong = 1
Detail = -3.21104
RefineSteps = 4
FudgeFactor = 0.74684
MaxRaySteps = 2000
MaxDistance = 250
Dither = 1
NormalBackStep = 0
DetailAO = -0.0007
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 1
AO_pointlight = 0
AoCorrect = 0
Specular = 1
SpecularExp = 7.765
CamLight = 1,0.870588,0.709804,0.4
AmbiantLight = 1,1,1,0.46808
Reflection = 0.443137,0.415686,0.333333
ReflectionsNumber = 1
SpotGlow = true
SpotLight = 1,0.768627,0.501961,1
LightPos = 6.6292,5.0562,5.1762
LightSize = 0.1134
LightFallOff = 0
LightGlowRad = 1.0461
LightGlowExp = 1
HardShadow = 1
ShadowSoft = 0.06173
ShadowBlur = 0.06024
perf = true
SSS = false
sss1 = 0.1
sss2 = 0.5
BaseColor = 0.443137,0.635294,0.717647
OrbitStrength = 0
X = 0.5,0.6,0.6,17.8
Y = 0.764706,0.705882,1,113.8
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,0.67346
BackgroundColor = 0.313725,0.6,0.541176
GradientBackground = 0.3
CycleColors = false
Cycles = 1.67844
EnableFloor = false
FloorNormal = 0,0,1
FloorHeight = 0
FloorColor = 1,1,1
HF_Fallof = 2.68443
HF_Const = 0.03261
HF_Intensity = 0.12783
HF_Dir = -0.04854,0.09338,-1
HF_Offset = -7.7084
HF_Color = 0.431373,0.513725,0.619608,1.70769
HF_Scatter = 0
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 1
HF_CastShadow = false
EnCloudsDir = false
Clouds_Dir = 0,0,1
CloudScale = 3.03337
CloudFlatness = 0.3893
CloudTops = 10
CloudBase = 2.405
CloudDensity = 0.38158
CloudRoughness = 0.91526
CloudContrast = 0.9375
CloudColor = 0.380392,0.462745,0.529412
CloudColor2 = 0.07,0.17,0.24
SunLightColor = 0.486275,0.513725,0.686275
Cloudvar1 = 0.99
Cloudvar2 = 0.99
CloudIter = 5
CloudBgMix = 1
GI = 16
GPow = 1
Gparam = 0.57142
Gnarl = 0,0
MI = 11
Size = 1.01666
CSize = 2,2,0.97346
C = -2,0,-0.15624
TThickness = 0.04546
DEoffset = 0.01
Offset = 0,0,0
Up = -0.07255,-0.0276972,-0.943211
#endpreset


#preset 2
FOV = 0.7731
Eye = 6.32659,6.34728,7.44193
Target = 2.20537,-2.74097,6.7942
FocalPlane = 0.79992
Aperture = 0
InFocusAWidth = 1
ApertureNbrSides = 2
ApertureRot = 0
ApStarShaped = false
Gamma = 0.8173
ToneMapping = 5
Exposure = 0.51063
Brightness = 1
Contrast = 1.8
Saturation = 1
GaussianWeight = 2
AntiAliasScale = 2
BloomIntensity = 0.08824
BloomPow = 3.7647
Detail = -3.1
FudgeFactor = 0.65823
MaxDistance = 10
Dither = 1
NormalBackStep = 0
Specular = 0
SpecularExp = 5.765
CamLight = 1,0.870588,0.709804,1
Reflection = 0.32549,0.333333,0.439216
SpotGlow = true
SpotLight = 1,0.768627,0.501961,1
LightPos = 6.6292,5.0562,5.1762
LightSize = 0.1134
LightFallOff = 0
LightGlowRad = 1.0461
LightGlowExp = 1
HardShadow = 1
BaseColor = 0.443137,0.635294,0.717647
OrbitStrength = 0.0274
BackgroundColor = 0.564706,0.745098,0.701961
GradientBackground = 0
EnableFloor = false
FloorNormal = 0,1,0
FloorHeight = -1.75
FloorColor = 0.219608,0.603922,0.231373
HF_Fallof = 2.68443
HF_Const = 0.03261
HF_Intensity = 0.12783
HF_Dir = 0.04854,0.04854,-1
HF_Offset = -7.7084
HF_Color = 0.403922,0.611765,0.815686,1.43076
HF_Scatter = 9.1139
HF_Anisotropy = 0.054902,0.364706,0.45098
HF_FogIter = 16
HF_CastShadow = false
CloudScale = 0.58886
CloudFlatness = 0.8625
CloudTops = 8.5
CloudBase = 6.2026
CloudDensity = 0.46053
CloudRoughness = 1.18644
CloudContrast = 0
CloudColor = 0.737255,0.780392,0.827451
SunLightColor = 0.486275,0.513725,0.686275
GI = 10
GPow = 1
Gparam = 0.36734
Gnarl = 0.31579,1
MI = 11
Size = 1.38334
CSize = 2,0,1
C = 0.04024,2,-0.144
TThickness = 0.52272
DEoffset = 0.0401
Offset = 0.07692,0.17308,-0.07692
Bloom = true
BloomTaps = 20
RefineSteps = 4
MaxRaySteps = 2000
DetailAO = -0.0007
coneApertureAO = 0.5
maxIterAO = 20
FudgeAO = 1
AO_ambient = 0.7
AO_camlight = 0
AO_pointlight = 0
AoCorrect = 0
AmbiantLight = 1,1,1,0.46808
ReflectionsNumber = 0
ShadowSoft = 0.06173
X = 0.5,0.6,0.6,17.8
Y = 0.764706,0.705882,1,113.8
Z = 0.8,0.78,1,1
R = 0.4,0.7,1,0.67346
CycleColors = false
Cycles = 1.67844
Up = 0.00772476,0.0635133,-0.940293
#endpreset


