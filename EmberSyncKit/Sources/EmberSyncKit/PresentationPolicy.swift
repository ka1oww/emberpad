public struct PresentationPolicy: Equatable, Sendable {
    public let hidePrivateContent: Bool
    public let pauseStudentView: Bool

    public init(captureActive: Bool, externalSceneCount: Int, mainSceneActive: Bool) {
        hidePrivateContent = !mainSceneActive || (captureActive && externalSceneCount == 0)
        pauseStudentView = !mainSceneActive
    }
}
