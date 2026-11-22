#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include "rgb2ycbcr.h"

float ofClamp(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}
std::vector<double> clear_color, style_color;
void ofSetColor(int r, int g, int b, int a=255) { style_color={double(r),double(g),double(b),double(a)}; }
void ofClear(float r, float g, float b, float a) { clear_color={r/255.,g/255.,b/255.,a/255.}; }
int ofGetWindowWidth() { return 1920; }
int ofGetWindowHeight() { return 1080; }
struct Texture { void bind() {} void unbind() {} };
// Pixel containers shaped like ofPixels/ofFloatPixels (only the members
// normalizeImageSourcePixels touches: getNumChannels/getData/width/height).
template <typename T>
struct Pixels {
    std::vector<T> data; int w=0,h=0,nch=0; int updates=0;
    int getNumChannels() const { return nch; }
    int getWidth() const { return w; }
    int getHeight() const { return h; }
    T *getData() { return data.data(); }
    void update() { ++updates; }
};
using ofPixels = Pixels<unsigned char>;
using ofFloatPixels = Pixels<float>;
struct Image {
    Texture texture; Texture &getTexture() { return texture; }
    ofPixels px; ofPixels &getPixels() { return px; }
    void update() { ++px.updates; }
};
struct FloatImage {
    Texture texture; Texture &getTexture() { return texture; }
    ofFloatPixels px; ofFloatPixels &getPixels() { return px; }
    void update() { ++px.updates; }
};
struct Fbo { void begin() {} void end() {} };
struct Shader {
    std::map<std::string,std::vector<double>> values;
    bool active=false;
    void begin() { active=true; }
    void end() { active=false; }
    void setUniform1i(const char *n,int a) { values[n]={double(a)}; }
    void setUniform2f(const char *n,float a,float b) { values[n]={a,b}; }
    void setUniform3f(const char *n,float a,float b,float c) { values[n]={a,b,c}; }
    void setUniform3i(const char *n,int a,int b,int c) { values[n]={double(a),double(b),double(c)}; }
};
struct ofxRPI4Window {
    static int bit_depth,isHDR,isDoVi,is_std_DoVi,colorspace_on,shader_init,dv_profile;
    struct AVI { int output_format=1,rgb_quant_range=1,colorimetry=2,max_bpc=10; };
    static AVI avi_info;
    static Shader shader;
    // The real rgbLimitedPassthroughSupported reads /sys/module/vc4; the
    // fixture drives it with this marker (0 stock kernel, 1 patched RQ3V1).
    static int pgen_rq_marker;
    static bool rgbLimitedPassthroughSupported() { return pgen_rq_marker!=0; }
    // Real predicate and wire mapping are injected below from ofxRPI4Window.cpp.
    static bool rgbLimitedPassthrough();
    static uint64_t wireRgbQuantRange(int rgb_quant_range, int output_format);
    // COLOUR_SHADER_PREDICATE
};
int ofxRPI4Window::bit_depth=10,ofxRPI4Window::isHDR=0,ofxRPI4Window::isDoVi=0;
int ofxRPI4Window::is_std_DoVi=0,ofxRPI4Window::colorspace_on=1,ofxRPI4Window::shader_init=0,ofxRPI4Window::dv_profile=2;
ofxRPI4Window::AVI ofxRPI4Window::avi_info;
Shader ofxRPI4Window::shader;
int ofxRPI4Window::pgen_rq_marker=0;
class ofApp {
public:
    int i=0,to_draw=0,solid_red=0,solid_green=0,solid_blue=0;
    int dv_source_red=0,dv_source_green=0,dv_source_blue=0,dv_source_max=255;
    int arr_source_range[1][1]={{0}},arr_source_max[1][1]={{1023}},arr_redbg[1][1]={{0}};
    float background_color[4]={0,0,0,1};
    std::vector<int> dv_background;
    Image img;
    FloatImage float_img;
    Fbo fbo8,fbo10;
    void setColor(int,int,int);
    int normalizeSourceValue(int,int);
    void normalizeImageSourcePixels(int);
    void setBackground(int,int,int);
    void clearBackground(int,int,int,int);
    void restoreBackground();
    void setDoViBackground(int r,int g,int b) { dv_background={r,g,b}; }
    void shader_begin(int);
    void shader_end(int);
};
// REAL_PRECISION_METHODS
// REAL_UNITY_METHODS

void require(bool ok,const char *message) { if(!ok) throw std::runtime_error(message); }
int packed(double value,int maximum) { return int(std::floor(value*maximum+0.5)); }
int main() {
    try {
        ofApp app;
        auto &window=ofxRPI4Window::avi_info;
        auto &shader=ofxRPI4Window::shader;
        for(int hdr : {0,1}) for(int bits : {8,10,12}) for(int format : {0,1,2}) for(int range : {0,1,2}) for(int marker : {0,1}) {
            ofxRPI4Window::isHDR=hdr;
            ofxRPI4Window::bit_depth=bits;
            ofxRPI4Window::pgen_rq_marker=marker;
            window.output_format=format; window.rgb_quant_range=range;
            int maximum=(1<<bits)-1;
            int black=16<<(bits-8),span=219<<(bits-8);
            // The real predicate, not a reimplementation: this is what the
            // production normalizeSourceValue consults.
            bool unity=ofxRPI4Window::rgbLimitedPassthrough();
            auto clampv=[&](int v){return std::max(0,std::min(maximum,v));};
            // Mirror of normalizeSourceValue for all three kernels:
            // legacy expansion, unity Limited pass-through, unity
            // full-range compression (exact 219/255, no hardware CSC).
            auto model_norm=[&](int v,int sr)->int{
                if(format!=0||range!=1||ofxRPI4Window::isDoVi||ofxRPI4Window::is_std_DoVi) return v;
                if(unity) return sr==1 ? v : clampv(black+int(std::floor(v*double(span)/maximum+0.5)));
                return sr==1 ? clampv(int(std::floor((v-black)*double(maximum)/span+0.5))) : v;
            };
            for(int code=0;code<=maximum;++code) {
                app.arr_source_range[0][0]=0;
                app.setColor(code,maximum-code,code/2);
                app.shader_begin(0);
                require(shader.active==(format!=0 || bits!=8),"wrong shader selection");
                if(shader.active) {
                    std::vector<double> want{(double)model_norm(code,0),(double)model_norm(maximum-code,0),(double)model_norm(code/2,0)};
                    require(shader.values["source_codes"]==want,"solid code was quantized");
                    require(shader.values["source_normalizer"][0]==maximum,"wrong source domain");
                }
                app.shader_end(0);
                app.setBackground(code,code,code);
                int bg=unity ? model_norm(code,0) : code; // YCbCr: format!=0 keeps code
                std::vector<int> expected=format==1 ? std::vector<int>{128<<(bits-8),128<<(bits-8),bg}
                    : format==2 ? std::vector<int>{bg,128<<(bits-8),128<<(bits-8)} : std::vector<int>{bg,bg,bg};
                for(int channel=0;channel<3;++channel)
                    require(packed(clear_color[channel],maximum)==expected[channel],"background lost precision");
                auto previous=clear_color;
                ofClear(0,0,0,0); // OF automatic clear at the next frame
                app.restoreBackground();
                app.arr_redbg[0][0]=-1;
                app.setBackground(-1,-1,-1);
                require(clear_color==previous,"BG=-1 lost previous surround");
                app.arr_redbg[0][0]=0;
                app.arr_source_range[0][0]=1;
                int expected_code=model_norm(code,1);
                require(app.normalizeSourceValue(code,1)==expected_code,"range conversion disagrees with wire domain");
                // Full-range source: unity compresses here, legacy defers to the kernel CSC.
                app.arr_source_range[0][0]=0;
                require(app.normalizeSourceValue(code,0)==model_norm(code,0),"full-range compression wrong");
                app.arr_source_range[0][0]=1;
                app.setColor(code,code,code);
                app.shader_begin(0);
                if(shader.active) require(shader.values["source_codes"][0]==expected_code,"range normalized twice");
                app.shader_end(0);
            }
            if(format!=0) {
                app.arr_source_range[0][0]=0;
                app.setBackground(maximum,0,0);
                double y=0.2126*maximum;
                double ratio=range==1 ? 224./219 : 256./255;
                int yy=int(std::floor(y+0.5));
                int cb=int(std::floor(-y/1.8556*ratio+(128<<(bits-8))+0.5));
                int cr=int(std::floor((maximum-y)/1.5748*ratio+(128<<(bits-8))+0.5));
                std::vector<int> expected=format==1 ? std::vector<int>{cb,cr,yy} : std::vector<int>{yy,cb,cr};
                for(int channel=0;channel<3;++channel)
                    require(packed(clear_color[channel],maximum)==std::max(0,std::min(maximum,expected[channel])),"coloured surround matrix or default range changed");
            }
        }
        // Issue 74: with the patched (unity) vc4 every RGB Limited wire code
        // must reach the HDMI block bit-exact, and the marker must gate all
        // of it: a stock kernel keeps the legacy expand/round-trip path.
        ofxRPI4Window::isHDR=0; ofxRPI4Window::isDoVi=0; ofxRPI4Window::is_std_DoVi=0;
        window.output_format=0; window.rgb_quant_range=1;
        for(int marker : {0,1}) {
            ofxRPI4Window::pgen_rq_marker=marker;
            bool unity=marker!=0;
            require(ofxRPI4Window::rgbLimitedPassthrough()==unity,"unity predicate must track the kernel marker");
            require((ofxRPI4Window::wireRgbQuantRange(1,0)==3)==unity,"only the patched kernel may signal range 3");
            require(ofxRPI4Window::wireRgbQuantRange(0,0)==0 && ofxRPI4Window::wireRgbQuantRange(2,0)==2,"auto/full signalling changed");
            require(ofxRPI4Window::wireRgbQuantRange(1,1)==1,"YCbCr must not get unity signalling");
            ofxRPI4Window::isDoVi=1;
            require(!ofxRPI4Window::rgbLimitedPassthrough() && ofxRPI4Window::wireRgbQuantRange(1,0)==1,"DV must keep the kernel CSC");
            ofxRPI4Window::isDoVi=0;
            if(!unity) continue;
            // Full Limited sweep at the sweep depths: framebuffer == wire.
            for(int bits : {8,10}) {
                ofxRPI4Window::bit_depth=bits;
                int maximum=(1<<bits)-1,black=16<<(bits-8),white=235<<(bits-8);
                for(int wire=0;wire<=maximum;++wire) {
                    app.arr_source_range[0][0]=1;
                    require(app.normalizeSourceValue(wire,1)==wire,"unity dropped a Limited wire code");
                    if(bits==8 && wire==153) require(app.normalizeSourceValue(153,1)==153,
                        "unity must not repeat the 153->154 drift of the 0x1b80 gain");
                }
                app.arr_source_range[0][0]=1;
                app.setBackground(black,black,black);
                require(packed(clear_color[0],maximum)==black && packed(clear_color[1],maximum)==black
                    && packed(clear_color[2],maximum)==black,"unity lost the Limited black surround");
                app.setBackground(white,white,white);
                require(packed(clear_color[0],maximum)==white,"unity lost the Limited white surround");
            }
        }
        // Issue 74: IMAGE textures bypass setColor(); under unity the kernel
        // no longer compresses, so normalizeImageSourcePixels must do it:
        // studio-range texels stay untouched, full-range texels compress
        // exactly (8-bit integer path and the 10-bit HDR float path).
        ofxRPI4Window::is_std_DoVi=0;
        auto set_img=[&](std::vector<unsigned char> d,int nch){
            app.img.px.data=std::move(d); app.img.px.w=1; app.img.px.h=(int)app.img.px.data.size()/nch; app.img.px.nch=nch; };
        auto set_fimg=[&](std::vector<float> d,int nch){
            app.float_img.px.data=std::move(d); app.float_img.px.w=1; app.float_img.px.h=(int)app.float_img.px.data.size()/nch; app.float_img.px.nch=nch; };
        window.output_format=0; window.rgb_quant_range=1;
        for(int marker : {0,1}) {
            ofxRPI4Window::pgen_rq_marker=marker;
            bool unity=marker!=0;
            // 8-bit path: RGBA, alpha must never move; grey channel mirrors R/G/B.
            // isHDR must be re-established per iteration: the float-path block
            // below flips it, and the production branch keys on max_bpc==10&&isHDR.
            ofxRPI4Window::isHDR=0;
            for(int sr : {0,1}) {
                set_img({0,64,127,235,255,0,2,128},4); // 2 RGBA pixels: grey triplets + untouched alpha
                app.normalizeImageSourcePixels(sr);
                unsigned char a0=app.img.px.data[0],a1=app.img.px.data[1],a2=app.img.px.data[2];
                if(unity && sr==0) {
                    require(a0==16 && a1==(unsigned char)(16+(64*219+127)/255) && a2==(unsigned char)(16+(127*219+127)/255),
                            "unity lost exact full-range image compression (8-bit)");
                    require(app.img.px.data[3]==235 && app.img.px.data[7]==128,"image alpha channel was rewritten");
                    require(app.img.px.data[4]==235 && app.img.px.data[5]==16 && app.img.px.data[6]==18,
                            "8-bit image compression wrong at endpoints (255/0/2)");
                } else if(unity && sr==1) {
                    require(a0==0 && a1==64 && a2==127,"unity expanded or folded studio-range image texels");
                } else if(!unity && sr==1) {
                    require(a0==0 && a1==(unsigned char)std::min(255,std::max(0,((64-16)*255+219/2)/219))
                            && a2==(unsigned char)std::min(255,std::max(0,((127-16)*255+219/2)/219)),
                            "stock image expansion changed");
                } else {
                    require(a0==0 && a1==64 && a2==127,"stock full-range image path touched texels");
                }
            }
            // 10-bit HDR float path (max_bpc==10 && isHDR).
            ofxRPI4Window::isHDR=1; window.max_bpc=10;
            for(int sr : {0,1}) {
                set_fimg({0.0f,64.0f/255.0f,1.0f,0.5f},4); // one RGBA pixel
                app.normalizeImageSourcePixels(sr);
                float v0=app.float_img.px.data[0],v1=app.float_img.px.data[1],v2=app.float_img.px.data[2];
                auto nearp=[](float a,float b){ return std::fabs(a-b)<1e-5f; };
                if(unity && sr==0) {
                    require(nearp(v0,16.0f/255.0f) && nearp(v1,(16.0f+64.0f*219.0f/255.0f)/255.0f) && nearp(v2,235.0f/255.0f),
                            "unity lost exact full-range image compression (10-bit float)");
                } else if(unity && sr==1) {
                    require(nearp(v0,0.0f) && nearp(v1,64.0f/255.0f),"unity touched studio-range float texels");
                } else if(!unity && sr==1) {
                    float exp=(64.0f/255.0f-16.0f/255.0f)*(255.0f/219.0f);
                    require(nearp(v0,0.0f) && nearp(v1,exp),"stock float image expansion changed");
                } else {
                    require(nearp(v0,0.0f) && nearp(v1,64.0f/255.0f),"stock full-range float path touched texels");
                }
            }
            ofxRPI4Window::isHDR=0; window.max_bpc=10;
        }
        ofxRPI4Window::pgen_rq_marker=0;
        window.output_format=1;
        ofxRPI4Window::bit_depth=10;
        app.shader_begin(1);
        require(shader.values["is_image"][0]==1,"texture path changed");
        app.shader_end(1);
        window.output_format=0;
        window.rgb_quant_range=1;
        for(int bits : {8,10}) for(int profile : {1,2}) for(int range : {0,1}) {
            ofxRPI4Window::bit_depth=bits;
            ofxRPI4Window::dv_profile=profile;
            app.arr_source_range[0][0]=range;
            // Revisit domains in both directions to catch stale source_max.
            for(int source_max : {255,1023,4095,1023,255,0}) {
                ofxRPI4Window::is_std_DoVi=1;
                ofxRPI4Window::isDoVi=1;
                app.arr_source_max[0][0]=source_max;
                int maximum=source_max ? source_max : 255;
                // Backgrounds retain the original DV domain even though the
                // tunnel surface is only 8/10 bits. BG=-1 must not repack it.
                app.dv_background.clear();
                app.setBackground(maximum,maximum/2,0);
                require(app.dv_background==std::vector<int>({maximum,maximum/2,0}),"DV background source domain changed");
                app.arr_redbg[0][0]=-1;
                app.setBackground(-1,-1,-1);
                require(app.dv_background==std::vector<int>({maximum,maximum/2,0}),"BG=-1 changed DV background");
                app.arr_redbg[0][0]=0;
                for(int code=-1;code<=maximum+1;++code) {
                    app.setColor(code,maximum-code,code/2);
                    // Every draw must upload both DV inputs; old values cannot
                    // make a missing upload appear to pass this check.
                    shader.values.clear();
                    app.shader_begin(0);
                    require(shader.active,"DV shader did not begin");
                    require(shader.values.at("source_rgb")==std::vector<double>({
                        double(std::max(0,std::min(maximum,code))),
                        double(std::max(0,std::min(maximum,maximum-code))),
                        double(std::max(0,std::min(maximum,code/2)))}),"DV codes changed");
                    require(shader.values.at("source_max")[0]==maximum,"DV source domain changed");
                    require(!shader.values.count("source_codes") && !shader.values.count("source_normalizer"),
                        "DV used link-depth inputs instead of original source codes");
                    app.shader_end(0);
                    require(!shader.active,"DV shader did not end");
                }
                // Switching back to SDR must replace the previous DV inputs.
                ofxRPI4Window::is_std_DoVi=0;
                ofxRPI4Window::isDoVi=0;
                window.output_format=1;
                app.setColor(81,84,85);
                shader.values.clear();
                app.shader_begin(0);
                require(shader.active,"SDR shader did not begin after DV");
                require(shader.values.at("source_codes")==std::vector<double>({81,84,85}),"SDR reused DV codes");
                require(shader.values.at("source_normalizer")[0]==(1<<bits)-1,"SDR reused DV source domain");
                require(!shader.values.count("source_rgb") && !shader.values.count("source_max"),"SDR uploaded DV inputs");
                app.shader_end(0);
                require(!shader.active,"SDR shader did not end after DV");
                window.output_format=0;
            }
        }
        std::cout << "Real renderer paths preserve every 8/10/12-bit code and DV source inputs\n";
        return 0;
    } catch(const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
