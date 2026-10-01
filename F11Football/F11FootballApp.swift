import SwiftUI
import SpriteKit

@main
struct F11FootballApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

struct GameView: View {
    private var scene: FootballScene {
        let s = FootballScene(size: CGSize(width: 1280, height: 720))
        s.scaleMode = .aspectFill
        return s
    }
    var body: some View {
        SpriteView(scene: scene, options: [.ignoresSiblingOrder])
            .background(Color.black)
            .persistentSystemOverlays(.hidden)
    }
}

final class FootballScene: SKScene, SKPhysicsContactDelegate {
    enum Team { case blue, red }
    final class Player: SKShapeNode {
        let team: Team
        var home = CGPoint.zero
        var velocity = CGVector.zero
        var isKeeper = false
        init(team: Team, number: Int) {
            self.team = team
            super.init()
            path = CGPath(ellipseIn: CGRect(x:-15,y:-15,width:30,height:30), transform:nil)
            fillColor = team ==  .blue ? .systemBlue : .systemRed
            strokeColor = .white; lineWidth = 2
            let n = SKLabelNode(text:"\(number)"); n.fontName = "AvenirNext-Bold"; n.fontSize = 12; n.verticalAlignmentMode = .center; addChild(n)
            physicsBody = SKPhysicsBody(circleOfRadius:15); physicsBody?.isDynamic = true; physicsBody?.affectedByGravity = false
            physicsBody?.allowsRotation = false; physicsBody?.linearDamping = 5
        }
        required init?(coder:NSCoder){ fatalError() }
    }

    private var blue:[Player] = [], red:[Player] = []
    private var controlled: Player!
    private let ball = SKShapeNode(circleOfRadius:9)
    private let joyBase = SKShapeNode(circleOfRadius:62), joyKnob = SKShapeNode(circleOfRadius:27)
    private let passButton = SKShapeNode(circleOfRadius:42), shootButton = SKShapeNode(circleOfRadius:48), sprintButton = SKShapeNode(circleOfRadius:36)
    private let scoreLabel = SKLabelNode(fontNamed:"AvenirNext-Heavy"), timeLabel = SKLabelNode(fontNamed:"AvenirNext-Bold")
    private var joyTouch:UITouch?, joyVector = CGVector.zero
    private var scoreBlue = 0, scoreRed = 0, elapsed:TimeInterval = 0, lastUpdate:TimeInterval = 0, ended = false
    private let pitch = CGRect(x:95,y:65,width:1090,height:590)

    override func didMove(to view:SKView) {
        backgroundColor = SKColor(red:0.025,green:0.08,blue:0.04,alpha:1)
        physicsWorld.gravity = .zero; physicsWorld.contactDelegate = self
        buildPitch(); buildTeams(); buildHUD(); resetKickoff()
    }

    private func line(_ a:CGPoint,_ b:CGPoint,_ width:CGFloat = 3){
        let p = CGMutablePath();p.move(to:a);p.addLine(to:b)
        let n = SKShapeNode(path:p);n.strokeColor = SKColor.white.withAlphaComponent(0.75);n.lineWidth = width;n.zPosition = 1;addChild(n)
    }
    private func buildPitch(){
        let grass = SKShapeNode(rect:pitch,cornerRadius:3);grass.fillColor = SKColor(red:0.08,green:0.43,blue:0.17,alpha:1);grass.strokeColor = .white;grass.lineWidth = 4;addChild(grass)
        for i in 0..<10 { let stripe = SKShapeNode(rect:CGRect(x:pitch.minX+CGFloat(i)*pitch.width/10,y:pitch.minY,width:pitch.width/10,height:pitch.height));stripe.fillColor = i%2 == 0 ? SKColor(white:1,alpha:0.035):.clear;stripe.strokeColor = .clear;stripe.zPosition = 0.5;addChild(stripe)}
        line(CGPoint(x:640,y:pitch.minY),CGPoint(x:640,y:pitch.maxY))
        let c = SKShapeNode(circleOfRadius:78);c.position = CGPoint(x:640,y:360);c.strokeColor = .white;c.lineWidth = 3;c.fillColor = .clear;c.zPosition = 1;addChild(c)
        for x in [pitch.minX,pitch.maxX-145] { let box = SKShapeNode(rect:CGRect(x:x,y:215,width:145,height:290));box.strokeColor = .white;box.lineWidth = 3;box.fillColor = .clear;box.zPosition = 1;addChild(box)}
        for x in [pitch.minX-28,pitch.maxX] { let goal = SKShapeNode(rect:CGRect(x:x,y:285,width:28,height:150));goal.strokeColor = .white;goal.lineWidth = 4;goal.fillColor = SKColor.white.withAlphaComponent(0.08);addChild(goal)}
        let border = SKPhysicsBody(edgeLoopFrom:pitch);border.friction = 0;border.restitution = 0.72;physicsBody = border
    }
    private func buildTeams(){
        let ys:[CGFloat] = [360,160,285,435,560,170,300,420,550,280,440]
        let bx:[CGFloat] = [125,315,315,315,315,510,510,510,510,600,600]
        let rx = bx.map{1280-$0}
        for i in 0..<11 {
            let b = Player(team:.blue,number:i+1);b.position = CGPoint(x:bx[i],y:ys[i]);b.home = b.position;b.isKeeper = i == 0;addChild(b);blue.append(b)
            let r = Player(team:.red,number:i+1);r.position = CGPoint(x:rx[i],y:ys[i]);r.home = r.position;r.isKeeper = i == 0;addChild(r);red.append(r)
        }
        controlled = blue[9]
        ball.fillColor = .white;ball.strokeColor = .black;ball.lineWidth = 2;ball.zPosition = 5
        ball.physicsBody = SKPhysicsBody(circleOfRadius:9);ball.physicsBody?.affectedByGravity = false;ball.physicsBody?.linearDamping = 0.75;ball.physicsBody?.restitution = 0.55
        addChild(ball)
    }
    private func button(_ n:SKShapeNode,_ pos:CGPoint,_ text:String,_ size:CGFloat){
        n.position = pos;n.fillColor = SKColor.black.withAlphaComponent(0.35);n.strokeColor = SKColor.white.withAlphaComponent(0.75);n.lineWidth = 3;n.zPosition = 20;addChild(n)
        let l = SKLabelNode(text:text);l.fontName = "AvenirNext-Bold";l.fontSize = size;l.verticalAlignmentMode = .center;l.zPosition = 21;n.addChild(l)
    }
    private func buildHUD(){
        joyBase.position = CGPoint(x:115,y:120);joyBase.fillColor = SKColor.black.withAlphaComponent(0.22);joyBase.strokeColor = SKColor.white.withAlphaComponent(0.28);joyBase.lineWidth = 3;joyBase.zPosition = 20;addChild(joyBase)
        joyKnob.fillColor = SKColor.white.withAlphaComponent(0.35);joyKnob.strokeColor = .white;joyKnob.zPosition = 21;joyBase.addChild(joyKnob)
        button(passButton,CGPoint(x:1110,y:115),"PASS",15);button(shootButton,CGPoint(x:1190,y:190),"SHOOT",14);button(sprintButton,CGPoint(x:1018,y:190),"RUN",13)
        scoreLabel.position = CGPoint(x:640,y:674);scoreLabel.fontSize = 28;scoreLabel.zPosition = 30;addChild(scoreLabel)
        timeLabel.position = CGPoint(x:640,y:640);timeLabel.fontSize = 18;timeLabel.zPosition = 30;addChild(timeLabel)
        updateScore()
    }
    private func updateScore(){scoreLabel.text = "F11 BLUE  \(scoreBlue)  —  \(scoreRed)  RED";timeLabel.text = String(format:"%02d:%02d",Int(elapsed)/60,Int(elapsed)%60)}
    private func resetKickoff(){
        ball.position = CGPoint(x:640,y:360);ball.physicsBody?.velocity = .zero
        for p in blue+red {p.position = p.home;p.physicsBody?.velocity = .zero}
        controlled = blue[9]
    }
    override func update(_ currentTime:TimeInterval){
        if lastUpdate == 0 {lastUpdate = currentTime};let dt = min(currentTime-lastUpdate,0.04);lastUpdate = currentTime
        if ended{return};elapsed += dt
        if elapsed >= 300 {ended = true;showEnd();return}
        updateScore(); updateControlled(); updateAI(red,attackingLeft:true); updateAI(blue.filter{$0 !==  controlled},attackingLeft:false); keepBallInPlay(); selectNearest()
    }
    private func updateControlled(){
        let speed:CGFloat = 245
        controlled.physicsBody?.velocity = CGVector(dx:joyVector.dx*speed,dy:joyVector.dy*speed)
        let ring = SKShapeNode(circleOfRadius:20); ring.name = "selection"
        childNode(withName:"selection")?.removeFromParent();ring.position = controlled.position;ring.strokeColor = .systemYellow;ring.lineWidth = 3;ring.zPosition = 2;ring.name = "selection";addChild(ring)
    }
    private func updateAI(_ team:[Player],attackingLeft:Bool){
        for p in team {
            let d = hypot(ball.position.x-p.position.x,ball.position.y-p.position.y)
            var target = p.home
            if p.isKeeper { target = CGPoint(x:attackingLeft ? pitch.maxX-28:pitch.minX+28,y:min(430,max(290,ball.position.y))) }
            else if d < 185 || nearest(to:ball.position,in:team) === p {target = ball.position}
            else { target.x += (ball.position.x-640)*0.16;target.y += (ball.position.y-360)*0.12 }
            let dx = target.x-p.position.x,dy = target.y-p.position.y,len = max(1,hypot(dx,dy))
            p.physicsBody?.velocity = CGVector(dx:dx/len*155,dy:dy/len*155)
            if d<30 { let dir:CGFloat = attackingLeft ? -1:1; ball.physicsBody?.applyImpulse(CGVector(dx:dir*5.2,dy:(360-p.position.y)*0.012)) }
        }
    }
    private func nearest(to pt:CGPoint,in arr:[Player])->Player? {arr.min{hypot($0.position.x-pt.x,$0.position.y-pt.y)<hypot($1.position.x-pt.x,$1.position.y-pt.y)}}
    private func selectNearest(){ if hypot(controlled.position.x-ball.position.x,controlled.position.y-ball.position.y)>220,let n = nearest(to:ball.position,in:blue.filter{!$0.isKeeper}) {controlled = n} }
    private func kick(power:CGFloat, pass:Bool){
        guard hypot(controlled.position.x-ball.position.x,controlled.position.y-ball.position.y)<48 else{return}
        var v = CGVector(dx:1,dy:0)
        if pass {
            let mates = blue.filter{$0 !==  controlled && $0.position.x>controlled.position.x-20}
            if let t = mates.min(by:{hypot($0.position.x-controlled.position.x-150,$0.position.y-controlled.position.y)<hypot($1.position.x-controlled.position.x-150,$1.position.y-controlled.position.y)}) {
                let dx = t.position.x-ball.position.x,dy = t.position.y-ball.position.y,l = max(1,hypot(dx,dy));v = CGVector(dx:dx/l,dy:dy/l)
            }
        } else if abs(joyVector.dx)+abs(joyVector.dy)>0.2 {v = joyVector}
        ball.physicsBody?.velocity = CGVector(dx:v.dx*power,dy:v.dy*power)
    }
    private func keepBallInPlay(){
        if ball.position.x < pitch.minX-7 && ball.position.y>285 && ball.position.y<435 {scoreRed += 1;resetKickoff()}
        if ball.position.x > pitch.maxX+7 && ball.position.y>285 && ball.position.y<435 {scoreBlue += 1;resetKickoff()}
    }
    private func showEnd(){
        let shade = SKShapeNode(rectOf:CGSize(width:620,height:230),cornerRadius:28);shade.position = CGPoint(x:640,y:360);shade.fillColor = SKColor.black.withAlphaComponent(0.82);shade.zPosition = 50;addChild(shade)
        let l = SKLabelNode(text:"FULL TIME  \(scoreBlue) — \(scoreRed)");l.fontName = "AvenirNext-Heavy";l.fontSize = 42;l.verticalAlignmentMode = .center;shade.addChild(l)
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){
        for t in touches {let p = t.location(in:self)
            if hypot(p.x-joyBase.position.x,p.y-joyBase.position.y)<100 {joyTouch = t;moveJoy(p)}
            else if hypot(p.x-passButton.position.x,p.y-passButton.position.y)<55 {kick(power:430,pass:true)}
            else if hypot(p.x-shootButton.position.x,p.y-shootButton.position.y)<65 {kick(power:720,pass:false)}
            else if hypot(p.x-sprintButton.position.x,p.y-sprintButton.position.y)<52 {controlled.physicsBody?.applyImpulse(CGVector(dx:joyVector.dx*8,dy:joyVector.dy*8))}
        }
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?){if let jt = joyTouch, touches.contains(jt){moveJoy(jt.location(in:self))}}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?){if let jt = joyTouch,touches.contains(jt){joyTouch = nil;joyVector = .zero;joyKnob.position = .zero}}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?){touchesEnded(touches,with:event)}
    private func moveJoy(_ p:CGPoint){let dx = p.x-joyBase.position.x,dy = p.y-joyBase.position.y,l = max(1,hypot(dx,dy)),m = min(55,l);joyVector = CGVector(dx:dx/l,dy:dy/l);joyKnob.position = CGPoint(x:joyVector.dx*m,y:joyVector.dy*m)}
}
