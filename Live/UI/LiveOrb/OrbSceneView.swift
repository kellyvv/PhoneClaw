import SwiftUI

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

// MARK: - OrbSceneView
//
// 这版不再尝试用 SceneKit 近似 audio-orb。
// 直接回到原始渲染链：
//   - Three.js
//   - IcosahedronGeometry
//   - 原版 sphere/backdrop shader
//   - EXRLoader + PMREM
//   - UnrealBloomPass
//
// Native 侧只负责把 analyser 的前三个 bin 推给网页渲染器。
// 为了避免之前那种 60fps 高频 bridge 带来的卡顿，这里 native -> JS 只做
// 约 30Hz 的目标值更新，帧内插值仍在 JS 的 requestAnimationFrame 中完成。

struct OrbSceneView: UIViewRepresentable {
    let inputAnalyser: OrbAudioAnalyser?
    let outputAnalyser: OrbAudioAnalyser?
    let state: LiveModeEngine.State

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.inputAnalyser = inputAnalyser
        context.coordinator.outputAnalyser = outputAnalyser
        context.coordinator.state = state
        context.coordinator.loadOrb(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.inputAnalyser = inputAnalyser
        context.coordinator.outputAnalyser = outputAnalyser
        context.coordinator.state = state
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var inputAnalyser: OrbAudioAnalyser?
        weak var outputAnalyser: OrbAudioAnalyser?
        var state: LiveModeEngine.State = .idle

        private weak var webView: WKWebView?
        private let schemeHandler = OrbBundleSchemeHandler()
        private var displayLink: CADisplayLink?
        private var isReady = false

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.userContentController.add(OrbLogBridge.shared, name: "orbLog")
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "orb")

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.navigationDelegate = self
            return webView
        }

        func loadOrb(into webView: WKWebView) {
            self.webView = webView
            isReady = false
            webView.loadHTMLString(OrbWebSource.html, baseURL: URL(string: "orb://bundle/"))

            if displayLink == nil {
                let displayLink = CADisplayLink(target: self, selector: #selector(tick))
                displayLink.preferredFramesPerSecond = 30
                displayLink.add(to: .main, forMode: .common)
                self.displayLink = displayLink
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
        }

        @objc private func tick() {
            guard isReady, let webView else { return }

            let input  = inputAnalyser?.snapshot3()  ?? (b0: 0, b1: 0, b2: 0, version: 0)
            let output = outputAnalyser?.snapshot3() ?? (b0: 0, b1: 0, b2: 0, version: 0)

            // state → brightness: idle=0 (暗), 其他=1 (亮)
            let brightness: Double = (state == .idle) ? 0.0 : 1.0

            let script = String(
                format: "window.__orbUpdate(%0.2f,%0.2f,%0.2f,%0.2f,%0.2f,%0.2f,%0.2f);",
                input.b0,  input.b1,  input.b2,
                output.b0, output.b1, output.b2,
                brightness
            )
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        deinit {
            displayLink?.invalidate()
        }
    }
}

private final class OrbLogBridge: NSObject, WKScriptMessageHandler {
    static let shared = OrbLogBridge()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[OrbWeb] \(message.body)")
    }
}

private final class OrbBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filename = path.isEmpty ? "index.html" : path
        let resourceName = (filename as NSString).deletingPathExtension
        let resourceExt = (filename as NSString).pathExtension

        guard let fileURL = Bundle.main.url(forResource: resourceName, withExtension: resourceExt.isEmpty ? nil : resourceExt) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType: String
            switch resourceExt.lowercased() {
            case "html": mimeType = "text/html"
            case "js": mimeType = "text/javascript"
            case "css": mimeType = "text/css"
            default: mimeType = "application/octet-stream"
            }

            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private enum OrbWebSource {
    static let html = #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #100c14;
    }
    canvas {
      width: 100% !important;
      height: 100% !important;
      position: absolute;
      inset: 0;
      image-rendering: pixelated;
      display: block;
    }
  </style>
</head>
<body>
  <canvas id="orb"></canvas>
  <div id="mask" style="position:absolute;inset:0;background:rgba(0,0,0,0.65);pointer-events:none;z-index:1;"></div>
  <script type="importmap">
    {
      "imports": {
        "three": "https://unpkg.com/three@0.176.0/build/three.module.js",
        "three/addons/": "https://unpkg.com/three@0.176.0/examples/jsm/"
      }
    }
  </script>
  <script type="module">
    const orbLog = (...parts) => {
      try {
        window.webkit?.messageHandlers?.orbLog?.postMessage(parts.join(' '));
      } catch {}
    };

    window.addEventListener('error', (event) => {
      orbLog('error', event.message, event.filename || '', String(event.lineno || 0));
    });

    window.addEventListener('unhandledrejection', (event) => {
      orbLog('rejection', String(event.reason || 'unknown'));
    });

    import * as THREE from 'three';
    import { EXRLoader } from 'three/addons/loaders/EXRLoader.js';
    import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
    import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
    import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';

    const backdropVS = `precision highp float;
in vec3 position;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
void main() {
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.);
}`;

    const backdropFS = `precision highp float;
out vec4 fragmentColor;
uniform vec2 resolution;
uniform float rand;
void main() {
  float aspectRatio = resolution.x / resolution.y;
  vec2 vUv = gl_FragCoord.xy / resolution;
  float noise = (fract(sin(dot(vUv, vec2(12.9898 + rand,78.233)*2.0)) * 43758.5453));
  vUv -= .5;
  vUv.x *= aspectRatio;
  float factor = 4.;
  float d = factor * length(vUv);
  vec3 from = vec3(3.) / 255.;
  vec3 to = vec3(16., 12., 20.) / 2550.;
  fragmentColor = vec4(mix(from, to, d) + .005 * noise, 1.);
}`;

    const sphereVS = `#define STANDARD
varying vec3 vViewPosition;
#ifdef USE_TRANSMISSION
  varying vec3 vWorldPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>

uniform float time;
uniform vec4 inputData;
uniform vec4 outputData;

vec3 calc( vec3 pos ) {
  vec3 dir = normalize( pos );
  vec3 p = dir + vec3( time, 0., 0. );
  return pos +
    1. * inputData.x * inputData.y * dir * (.5 + .5 * sin(inputData.z * pos.x + time)) +
    1. * outputData.x * outputData.y * dir * (.5 + .5 * sin(outputData.z * pos.y + time));
}

vec3 spherical( float r, float theta, float phi ) {
  return r * vec3(
    cos( theta ) * cos( phi ),
    sin( theta ) * cos( phi ),
    sin( phi )
  );
}

void main() {
  #include <uv_vertex>
  #include <color_vertex>
  #include <morphinstance_vertex>
  #include <morphcolor_vertex>
  #include <batching_vertex>
  #include <beginnormal_vertex>
  #include <morphnormal_vertex>
  #include <skinbase_vertex>
  #include <skinnormal_vertex>
  #include <defaultnormal_vertex>
  #include <normal_vertex>
  #include <begin_vertex>

  float inc = 0.001;
  float r = length( position );
  float theta = ( uv.x + 0.5 ) * 2. * PI;
  float phi = -( uv.y + 0.5 ) * PI;

  vec3 np = calc( spherical( r, theta, phi )  );
  vec3 tangent = normalize( calc( spherical( r, theta + inc, phi ) ) - np );
  vec3 bitangent = normalize( calc( spherical( r, theta, phi + inc ) ) - np );
  transformedNormal = -normalMatrix * normalize( cross( tangent, bitangent ) );
  vNormal = normalize( transformedNormal );
  transformed = np;

  #include <morphtarget_vertex>
  #include <skinning_vertex>
  #include <displacementmap_vertex>
  #include <project_vertex>
  #include <logdepthbuf_vertex>
  #include <clipping_planes_vertex>
  vViewPosition = - mvPosition.xyz;
  #include <worldpos_vertex>
  #include <shadowmap_vertex>
  #include <fog_vertex>
  #ifdef USE_TRANSMISSION
    vWorldPosition = worldPosition.xyz;
  #endif
}`;

    const canvas = document.getElementById('orb');
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x100c14);

    const backdrop = new THREE.Mesh(
      new THREE.IcosahedronGeometry(10, 5),
      new THREE.RawShaderMaterial({
        uniforms: {
          resolution: { value: new THREE.Vector2(1, 1) },
          rand: { value: 0 }
        },
        vertexShader: backdropVS,
        fragmentShader: backdropFS,
        glslVersion: THREE.GLSL3
      })
    );
    backdrop.material.side = THREE.BackSide;
    scene.add(backdrop);

    const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
    camera.position.set(2, -2, 5);

    const renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: false,
      powerPreference: 'high-performance'
    });
    renderer.setSize(window.innerWidth, window.innerHeight);
    renderer.setPixelRatio(window.devicePixelRatio);

    const geometry = new THREE.IcosahedronGeometry(1, 10);
    const pmremGenerator = new THREE.PMREMGenerator(renderer);
    pmremGenerator.compileEquirectangularShader();

    const baseEmissiveIntensity = 1.2;
    const sphereMaterial = new THREE.MeshStandardMaterial({
      color: 0x2a1a08,
      metalness: 0.85,
      roughness: 0.25,
      emissive: 0x1a0f04,
      emissiveIntensity: 1.2
    });

    sphereMaterial.onBeforeCompile = (shader) => {
      shader.uniforms.time = { value: 0 };
      shader.uniforms.inputData = { value: new THREE.Vector4() };
      shader.uniforms.outputData = { value: new THREE.Vector4() };
      sphereMaterial.userData.shader = shader;
      shader.vertexShader = sphereVS;
    };

    const sphere = new THREE.Mesh(geometry, sphereMaterial);
    sphere.visible = false;
    scene.add(sphere);

    new EXRLoader().load(
      'orb://bundle/piz_compressed.exr',
      (texture) => {
        texture.mapping = THREE.EquirectangularReflectionMapping;
        const exrCubeRenderTarget = pmremGenerator.fromEquirectangular(texture);
        sphereMaterial.envMap = exrCubeRenderTarget.texture;
        sphere.visible = true;
        orbLog('orb-ready');
      },
      undefined,
      (error) => {
        orbLog('exr-load-failed', String(error || 'unknown'));
        sphere.visible = true;
      }
    );

    const composer = new EffectComposer(renderer);
    composer.addPass(new RenderPass(scene, camera));
    const bloomPass = new UnrealBloomPass(
      new THREE.Vector2(window.innerWidth, window.innerHeight),
      0.3,   // 初始 bloom 很低 (加载中), 满值 5
      0.5,
      0
    );
    composer.addPass(bloomPass);
    const fullBloomStrength = 5;

    function onWindowResize() {
      camera.aspect = window.innerWidth / window.innerHeight;
      camera.updateProjectionMatrix();
      const dPR = renderer.getPixelRatio();
      const w = window.innerWidth;
      const h = window.innerHeight;
      backdrop.material.uniforms.resolution.value.set(w * dPR, h * dPR);
      renderer.setSize(w, h);
      composer.setSize(w, h);
    }

    window.addEventListener('resize', onWindowResize);
    onWindowResize();

    const input  = { x: 0, y: 0, z: 0 };
    const output = { x: 0, y: 0, z: 0 };
    const target = { ix: 0, iy: 0, iz: 0, ox: 0, oy: 0, oz: 0 };
    const baseDim = 0.12;
    let targetBrightness = 0;
    let currentBrightness = 0;
    const rotation = new THREE.Vector3(0, 0, 0);
    let prevTime = performance.now();

    // 蒙版控制: TTS 播放后 1s 延迟, 然后 6s 淡出 (wall-clock time)
    const mask = document.getElementById('mask');
    let maskOpacity = 0.65;
    let revealStartTime = -1;  // -1 = 未触发
    const revealDelayMs = 1000;   // 1s delay
    const revealDurationMs = 6000; // 6s ramp

    window.__orbUpdate = (i0, i1, i2, o0, o1, o2, br) => {
      target.ix = i0; target.iy = i1; target.iz = i2;
      target.ox = o0; target.oy = o1; target.oz = o2;
      if (br !== undefined && br > 0.5 && revealStartTime < 0) {
        revealStartTime = performance.now();
      }
    };

    function animate() {
      requestAnimationFrame(animate);

      const t = performance.now();
      const dt = (t - prevTime) / (1000 / 60);
      prevTime = t;

      // Lerp toward target — smooths IPC jitter
      const k = 0.25;
      input.x  += (target.ix - input.x)  * k;
      input.y  += (target.iy - input.y)  * k;
      input.z  += (target.iz - input.z)  * k;
      output.x += (target.ox - output.x) * k;
      output.y += (target.oy - output.y) * k;
      output.z += (target.oz - output.z) * k;

      backdrop.material.uniforms.rand.value = Math.random() * 10000;

      // 蒙版 + bloom: 1s delay + 6s 淡出 (wall-clock)
      if (revealStartTime >= 0) {
        const elapsed = t - revealStartTime;
        if (elapsed > revealDelayMs) {
          const progress = Math.min((elapsed - revealDelayMs) / revealDurationMs, 1.0);
          const eased = progress * progress * (3 - 2 * progress);
          maskOpacity = 0.65 * (1.0 - eased);
          bloomPass.strength = 0.3 + (fullBloomStrength - 0.3) * eased;
        }
      }
      mask.style.opacity = maskOpacity;

      if (sphereMaterial.userData.shader) {
        // 对齐原版：1 + (0.2 * data[1]) / 255
        sphere.scale.setScalar(1 + (0.2 * output.y) / 255);

        const f = 0.001;
        rotation.x += (dt * f * 0.5  * output.y) / 255;
        rotation.z += (dt * f * 0.5  * input.y)  / 255;
        rotation.y += (dt * f * 0.25 * input.z)  / 255;
        rotation.y += (dt * f * 0.25 * output.z) / 255;

        const euler = new THREE.Euler(rotation.x, rotation.y, rotation.z);
        const quaternion = new THREE.Quaternion().setFromEuler(euler);
        const vector = new THREE.Vector3(0, 0, 5);
        vector.applyQuaternion(quaternion);
        camera.position.copy(vector);
        // LookAt 下方一点, 让 sphere 出现在帧的上部, 给下方状态文字和
        // 对话区腾地方 (视觉上 Orb 上移)
        camera.lookAt(new THREE.Vector3(0, -0.5, 0));

        sphereMaterial.userData.shader.uniforms.time.value +=
          (dt * 0.1 * output.x) / 255;
        sphereMaterial.userData.shader.uniforms.inputData.value.set(
          (1    * input.x) / 255,
          (0.1  * input.y) / 255,
          (10   * input.z) / 255,
          0
        );
        sphereMaterial.userData.shader.uniforms.outputData.value.set(
          (2    * output.x) / 255,
          (0.1  * output.y) / 255,
          (10   * output.z) / 255,
          0
        );
      }

      composer.render();
    }

    animate();
  </script>
</body>
</html>
"""#
}

#else

struct OrbSceneView: View {
    let inputAnalyser: OrbAudioAnalyser?
    let outputAnalyser: OrbAudioAnalyser?
    let state: LiveModeEngine.State

    var body: some View {
        OrbBackgroundView()
    }
}

#endif
