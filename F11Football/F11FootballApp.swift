import SwiftUI
import SceneKit

@main
struct F11FootballApp: App {
    var body: some Scene {
        WindowGroup { MatchView().ignoresSafeArea().statusBarHidden(true) }
    }
}

struct MatchView: View {
    @StateObject private var game = FootballGame()
    var body: some View {
        ZStack {
            SceneView(scene: game.scene, pointOfView: game.cameraNode, options: [.rendersContinuously])
                .ignoresSafeArea()
                .onAppear { game.start() }
            VStack {
                HStack {
                    Text("BLUE  \(game.homeScore)")
                    Spacer()
                    Text(game.clockText).monospacedDigit()
                    Spacer()
                    Text("\(game.awayScore)  RED")
                }
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 10)
                .background(.black.opacity(0.62), in: Capsule()).padding(.top, 10).padding(.horizontal, 110)
                Spacer()
                HStack(alignment: .bottom) {
                    Joystick(vector: $game.input)
                        .frame(width: 150, height: 150)
                    Spacer()
                    VStack(spacing: 10) {
                        Button("PASS") { game.pass() }.buttonStyle(GameButtonStyle(size: 72))
                        HStack(spacing: 14) {
                            Button("SWITCH") { game.switchPlayer() }.buttonStyle(GameButtonStyle(size: 64))
                            Button("SHOOT") { game.shoot() }.buttonStyle(GameButtonStyle(size: 82))
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 18)
            }
            if game.finished {
                VStack(spacing: 12) {
                    Text("FULL TIME").font(.system(size: 42, weight: .black))
                    Text("\(game.homeScore)  —  \(game.awayScore)").font(.system(size: 34, weight: .bold))
                    Button("PLAY AGAIN") { game.restart() }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white).padding(35).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 28))
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct GameButtonStyle: ButtonStyle {
    let size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: size * 0.18, weight: .black))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(.black.opacity(configuration.isPressed ? 0.8 : 0.52), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

struct Joystick: View {
    @Binding var vector: CGVector
    @State private var knob = CGSize.zero
    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().fill(.black.opacity(0.38)).overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 2))
                Circle().fill(.white.opacity(0.68)).frame(width: radius * 0.72, height: radius * 0.72).offset(knob)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let c = CGPoint(x: geo.size.width/2, y: geo.size.height/2)
                var dx = value.location.x-c.x, dy = value.location.y-c.y
                let d = max(1, hypot(dx,dy)), limit = radius * 0.62
                if d > limit { dx *= limit/d; dy *= limit/d }
                knob = CGSize(width: dx, height: dy)
                vector = CGVector(dx: dx/limit, dy: -dy/limit)
            }.onEnded { _ in knob = .zero; vector = .zero })
        }
    }
}

@MainActor
final class FootballGame: NSObject, ObservableObject, SCNSceneRendererDelegate {
    enum Side { case home, away }
    final class Player {
        let node = SCNNode()
        let side: Side
        let number: Int
        let keeper: Bool
        var home = SCNVector3Zero
        var target = SCNVector3Zero
        init(side: Side, number: Int, keeper: Bool = false) {
            self.side = side; self.number = number; self.keeper = keeper
            let body = SCNCapsule(capRadius: 0.42, height: 1.72)
            body.firstMaterial?.diffuse.contents = side == .home ? UIColor.systemBlue : UIColor.systemRed
            body.firstMaterial?.roughness.contents = 0.75
            let torso = SCNNode(geometry: body); torso.position.y = 0.86; node.addChildNode(torso)
            let head = SCNSphere(radius: 0.25); head.firstMaterial?.diffuse.contents = UIColor(red:0.72,green:0.50,blue:0.34,alpha:1)
            let hn = SCNNode(geometry: head); hn.position.y = 1.9; node.addChildNode(hn)
        }
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    @Published var homeScore = 0
    @Published var awayScore = 0
    @Published var seconds = 180.0
    @Published var finished = false
    @Published var input = CGVector.zero
    var clockText: String { String(format: "%02d:%02d", Int(seconds)/60, Int(seconds)%60) }

    private var home:[Player] = [], away:[Player] = []
    private var controlled: Player!
    private let ball = SCNNode(geometry: SCNSphere(radius: 0.23))
    private let marker = SCNNode(geometry: SCNTorus(ringRadius: 0.62, pipeRadius: 0.045))
    private var last: TimeInterval = 0
    private var started = false
    private var possession: Player?
    private var ballVelocity = SCNVector3Zero
    private var shotCooldown = 0.0
    private let halfLength: Float = 52.5
    private let halfWidth: Float = 34
    private let goalHalf: Float = 3.66

    func start() {
        guard !started else { return }
        started = true; buildWorld(); kickoff()
    }

    private func buildWorld() {
        scene.background.contents = UIColor(red:0.035,green:0.07,blue:0.055,alpha:1)
        scene.physicsWorld.gravity = SCNVector3(0,-9.8,0)
        let grass = SCNPlane(width: 68, height: 105)
        grass.firstMaterial?.diffuse.contents = UIColor(red:0.08,green:0.39,blue:0.15,alpha:1)
        grass.firstMaterial?.roughness.contents = 1
        let field = SCNNode(geometry: grass); field.eulerAngles.x = -.pi/2; scene.rootNode.addChildNode(field)
        addLines(); addGoals(); addStadium()
        let light = SCNLight(); light.type = .directional; light.intensity = 1300
        let ln = SCNNode(); ln.light = light; ln.eulerAngles = SCNVector3(-1.0,0.4,0); scene.rootNode.addChildNode(ln)
        scene.rootNode.light = nil
        scene.lightingEnvironment.intensity = 0.6
        ball.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        ball.geometry?.firstMaterial?.metalness.contents = 0.05
        ball.position = SCNVector3(0,0.24,0); scene.rootNode.addChildNode(ball)
        marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        marker.eulerAngles.x = .pi/2; marker.position.y = 0.035; scene.rootNode.addChildNode(marker)
        createTeams()
        let cam = SCNCamera(); cam.fieldOfView = 60; cam.zFar = 350
        cameraNode.camera = cam; scene.rootNode.addChildNode(cameraNode)
    }

    private func line(_ w: CGFloat,_ h: CGFloat,_ x: Float,_ z: Float) {
        let p = SCNPlane(width:w,height:h); p.firstMaterial?.diffuse.contents = UIColor.white
        let n=SCNNode(geometry:p); n.eulerAngles.x = -.pi/2; n.position=SCNVector3(x,0.012,z); scene.rootNode.addChildNode(n)
    }
    private func addLines() {
        line(68,0.12,0,-52.5); line(68,0.12,0,52.5); line(0.12,105,-34,0); line(0.12,105,34,0); line(68,0.10,0,0)
        let ring=SCNTorus(ringRadius:9.15,pipeRadius:0.05); ring.firstMaterial?.diffuse.contents=UIColor.white
        let n=SCNNode(geometry:ring); n.position.y=0.02; scene.rootNode.addChildNode(n)
    }
    private func addGoals() {
        for z in [-halfLength,halfLength] {
            for x in [-goalHalf,goalHalf] {
                let post=SCNCylinder(radius:0.07,height:2.44); post.firstMaterial?.diffuse.contents=UIColor.white
                let n=SCNNode(geometry:post); n.position=SCNVector3(x,1.22,z); scene.rootNode.addChildNode(n)
            }
            let bar=SCNCylinder(radius:0.07,height:CGFloat(goalHalf*2)); bar.firstMaterial?.diffuse.contents=UIColor.white
            let bn=SCNNode(geometry:bar); bn.eulerAngles.z=.pi/2; bn.position=SCNVector3(0,2.44,z); scene.rootNode.addChildNode(bn)
        }
    }
    private func addStadium() {
        for side: Float in [-1,1] {
            let stand=SCNBox(width:8,height:7,length:112,chamferRadius:0.5); stand.firstMaterial?.diffuse.contents=UIColor.darkGray
            let n=SCNNode(geometry:stand); n.position=SCNVector3(side*40,3.5,0); scene.rootNode.addChildNode(n)
        }
    }

    private func createTeams() {
        let formation:[(Float,Float)] = [(0,-48),(-18,-35),( -6,-38),(6,-38),(18,-35),(-17,-15),(-5,-12),(7,-12),(18,-8),(-9,18),(9,22)]
        for i in 0..<11 {
            let h=Player(side:.home,number:i+1,keeper:i==0); h.home=SCNVector3(formation[i].0,0,formation[i].1); h.node.position=h.home; scene.rootNode.addChildNode(h.node); home.append(h)
            let a=Player(side:.away,number:i+1,keeper:i==0); a.home=SCNVector3(-formation[i].0,0,-formation[i].1); a.node.position=a.home; scene.rootNode.addChildNode(a.node); away.append(a)
        }
        controlled=home[9]
    }

    func restart() {
        homeScore=0; awayScore=0; seconds=180; finished=false; last=0; kickoff()
    }
    private func kickoff() {
        possession=nil; ballVelocity=SCNVector3Zero; ball.position=SCNVector3(0,0.24,0)
        for p in home+away { p.node.position=p.home }
        controlled=home[9]; marker.position=SCNVector3(controlled.node.position.x,0.04,controlled.node.position.z)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard started, !finished else { return }
        if last == 0 { last=time; return }
        let dt=min(0.033,time-last); last=time
        Task { @MainActor in self.tick(Float(dt)) }
    }

    private func tick(_ dt: Float) {
        seconds=max(0,seconds-Double(dt)); shotCooldown=max(0,shotCooldown-Double(dt))
        if seconds<=0 { finished=true; return }
        moveControlled(dt); updateAI(home, attackingPositive:true, dt:dt); updateAI(away, attackingPositive:false, dt:dt)
        updateBall(dt); updateCamera(dt); checkGoal()
    }

    private func moveControlled(_ dt: Float) {
        guard !controlled.keeper else { return }
        let speed:Float=8.8
        controlled.node.position.x += Float(input.dx)*speed*dt
        controlled.node.position.z += Float(input.dy)*speed*dt
        clamp(&controlled.node.position)
        if abs(input.dx)+abs(input.dy)>0.08 {
            controlled.node.eulerAngles.y=atan2(Float(input.dx),Float(input.dy))
        }
        marker.position=SCNVector3(controlled.node.position.x,0.04,controlled.node.position.z)
        if possession === controlled {
            let forward=SCNVector3(sin(controlled.node.eulerAngles.y),0,cos(controlled.node.eulerAngles.y))
            ball.position=SCNVector3(controlled.node.position.x+forward.x*0.75,0.24,controlled.node.position.z+forward.z*0.75)
        }
    }

    private func updateAI(_ team:[Player], attackingPositive:Bool, dt:Float) {
        let outfield=team.filter{ !$0.keeper && $0 !== controlled }
        let sorted=outfield.sorted{ dist($0.node.position,ball.position)<dist($1.node.position,ball.position) }
        let presser = sorted.first
        let support = sorted.dropFirst().first
        for p in team {
            if p === controlled { continue }
            var target=p.home
            if p.keeper {
                target.x=max(-goalHalf+0.5,min(goalHalf-0.5,ball.position.x*0.22))
                target.z = attackingPositive ? -50.2 : 50.2
            } else if possession?.side != p.side && (p === presser || (p === support && dist(p.node.position,ball.position)<9)) {
                target=ball.position
            } else {
                let shiftX=max(-7,min(7,ball.position.x*0.18))
                let shiftZ=max(-10,min(10,ball.position.z*0.16))
                target.x += shiftX
                target.z += shiftZ
            }
            move(p,toward:target,speed:p.keeper ? 5.8:6.4,dt:dt)
        }
    }

    private func move(_ p:Player,toward t:SCNVector3,speed:Float,dt:Float) {
        let dx=t.x-p.node.position.x,dz=t.z-p.node.position.z,d=max(0.001,sqrt(dx*dx+dz*dz))
        if d>0.25 { p.node.position.x += dx/d*min(speed*dt,d); p.node.position.z += dz/d*min(speed*dt,d); p.node.eulerAngles.y=atan2(dx,dz) }
        clamp(&p.node.position)
    }

    private func updateBall(_ dt:Float) {
        if possession == nil {
            ball.position.x += ballVelocity.x*dt; ball.position.z += ballVelocity.z*dt
            ballVelocity.x *= pow(0.985,dt*60); ballVelocity.z *= pow(0.985,dt*60)
            ball.position.y=0.24
            if abs(ball.position.x)>halfWidth { ball.position.x=max(-halfWidth,min(halfWidth,ball.position.x)); ballVelocity.x *= -0.55 }
            for p in home+away where !p.keeper {
                if dist(p.node.position,ball.position)<0.85 && hypot(ballVelocity.x,ballVelocity.z)<14 {
                    possession=p; ballVelocity=SCNVector3Zero
                    if p.side == .home && dist(controlled.node.position,p.node.position)>12 { controlled=p }
                    break
                }
            }
        } else if let p=possession, p !== controlled {
            let dir:Float = p.side == .home ? 1:-1
            ball.position=SCNVector3(p.node.position.x,0.24,p.node.position.z+dir*0.7)
            if p.side == .away && abs(p.node.position.z - home[0].node.position.z)<20 && shotCooldown<=0 {
                kick(from:p,velocity:SCNVector3((home[0].node.position.x-p.node.position.x)*0.7,0,-18)); shotCooldown=1.2
            }
        }
    }

    func pass() {
        guard possession === controlled || dist(controlled.node.position,ball.position)<1.2 else { return }
        let candidates=home.filter{$0 !== controlled && !$0.keeper}
        guard let t=candidates.min(by:{ passScore($0)<passScore($1) }) else{return}
        let dx=t.node.position.x-controlled.node.position.x,dz=t.node.position.z-controlled.node.position.z,d=max(0.1,sqrt(dx*dx+dz*dz))
        kick(from:controlled,velocity:SCNVector3(dx/d*13,0,dz/d*13))
    }
    private func passScore(_ p:Player)->Float {
        let forward=max(0,p.node.position.z-controlled.node.position.z)
        return dist(p.node.position,controlled.node.position)-forward*0.45
    }
    func shoot() {
        guard possession === controlled || dist(controlled.node.position,ball.position)<1.2 else{return}
        let dx = -controlled.node.position.x*0.12
        kick(from:controlled,velocity:SCNVector3(dx,0,22))
    }
    private func kick(from p:Player,velocity:SCNVector3) {
        possession=nil; ball.position=SCNVector3(p.node.position.x,0.24,p.node.position.z); ballVelocity=velocity
    }
    func switchPlayer() {
        let candidates=home.filter{!$0.keeper}
        if let p=candidates.min(by:{dist($0.node.position,ball.position)<dist($1.node.position,ball.position)}) { controlled=p; if possession?.side == .home { possession=p } }
    }

    private func checkGoal() {
        guard abs(ball.position.x)<goalHalf else{return}
        if ball.position.z > halfLength+0.15 { homeScore += 1; kickoff() }
        if ball.position.z < -halfLength-0.15 { awayScore += 1; kickoff() }
    }

    private func updateCamera(_ dt:Float) {
        let p=controlled.node.position
        let desired=SCNVector3(p.x*0.65,10.5,p.z-13)
        cameraNode.position.x += (desired.x-cameraNode.position.x)*min(1,dt*5)
        cameraNode.position.y += (desired.y-cameraNode.position.y)*min(1,dt*5)
        cameraNode.position.z += (desired.z-cameraNode.position.z)*min(1,dt*5)
        cameraNode.look(at:SCNVector3(p.x,0.8,p.z+7))
    }
    private func clamp(_ p:inout SCNVector3) { p.x=max(-halfWidth+0.6,min(halfWidth-0.6,p.x)); p.z=max(-halfLength+0.6,min(halfLength-0.6,p.z)) }
    private func dist(_ a:SCNVector3,_ b:SCNVector3)->Float { let x=a.x-b.x,z=a.z-b.z; return sqrt(x*x+z*z) }
}
