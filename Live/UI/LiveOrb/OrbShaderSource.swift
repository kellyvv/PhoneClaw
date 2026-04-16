// MARK: - OrbShaderSource
//
// 球体顶点形变 + 法线重建的 SceneKit Geometry Modifier（内联 Metal 源码字符串）。
//
// 交付方式说明：
//   SceneKit shaderModifiers[.geometry] 接受运行时 Metal 源码字符串，FirstLoad 时由
//   SceneKit 内部 Metal 编译器编译并缓存；不使用 .metal 文件，不进入 Build Phases。
//
// 算法来源：完整移植自 audio-orb/sphere-shader.ts
//   - 从 UV 重建球坐标（theta/phi），对应 JS spherical() 函数
//   - calc() 位移函数：沿法线方向正弦形变，分别由 inputData/outputData 驱动 X/Y 轴
//   - 有限差分法线重建：与 JS 的 tangent/bitangent/cross 完全等价
//   - 同时写回 _geometry.position.xyz 和 _geometry.normal

enum OrbShaderSource {

    static let geometryModifier: String = """
    #pragma arguments
    float  time;
    float4 inputData;
    float4 outputData;

    #pragma body
    {
        // ── 1. 从 UV 重建球坐标（对应 JS 的 theta/phi） ──
        float2 uv    = _geometry.texcoords[0].xy;
        float  r     = length(_geometry.position.xyz);
        float  theta = (uv.x + 0.5) * 6.28318530;   // 2π
        float  phi   = -(uv.y + 0.5) * 3.14159265;  // π

        // ── 2. 球坐标 → 直角坐标（inline spherical()） ──
        float3 base = r * float3(
            cos(theta) * cos(phi),
            sin(theta) * cos(phi),
            sin(phi)
        );

        // ── 3. 位移函数（inline calc()），inputData 驱动 X 轴，outputData 驱动 Y 轴 ──
        float3 dir = normalize(base);
        float3 np  = base
            + inputData.x  * inputData.y  * dir * (0.5 + 0.5 * sin(inputData.z  * base.x + time))
            + outputData.x * outputData.y * dir * (0.5 + 0.5 * sin(outputData.z * base.y + time));

        // ── 4. 有限差分法线重建（对应 JS tangent/bitangent/cross） ──
        float inc = 0.001;

        // theta + inc 方向的邻点
        float th1 = theta + inc;
        float3 base_t = r * float3(cos(th1)*cos(phi), sin(th1)*cos(phi), sin(phi));
        float3 dir_t  = normalize(base_t);
        float3 np_t   = base_t
            + inputData.x  * inputData.y  * dir_t * (0.5 + 0.5 * sin(inputData.z  * base_t.x + time))
            + outputData.x * outputData.y * dir_t * (0.5 + 0.5 * sin(outputData.z * base_t.y + time));

        // phi + inc 方向的邻点
        float ph1 = phi + inc;
        float3 base_p = r * float3(cos(theta)*cos(ph1), sin(theta)*cos(ph1), sin(ph1));
        float3 dir_p  = normalize(base_p);
        float3 np_p   = base_p
            + inputData.x  * inputData.y  * dir_p * (0.5 + 0.5 * sin(inputData.z  * base_p.x + time))
            + outputData.x * outputData.y * dir_p * (0.5 + 0.5 * sin(outputData.z * base_p.y + time));

        float3 tangent   = normalize(np_t - np);
        float3 bitangent = normalize(np_p - np);
        float3 newNormal = -normalize(cross(tangent, bitangent));

        // ── 5. 写回 ──
        _geometry.position.xyz = np;
        _geometry.normal       = newNormal;
    }
    """
}
