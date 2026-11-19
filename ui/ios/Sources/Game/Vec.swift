import SceneKit

// Minimal SCNVector3 math used by the game loop.
extension SCNVector3 {
    static func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: SCNVector3, s: Float) -> SCNVector3 { SCNVector3(a.x * s, a.y * s, a.z * s) }

    var length: Float { sqrtf(x * x + y * y + z * z) }
    var normalized: SCNVector3 { let l = length; return l > 1e-5 ? self * (1 / l) : SCNVector3Zero }
    func distance(to o: SCNVector3) -> Float { (self - o).length }
}

func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
