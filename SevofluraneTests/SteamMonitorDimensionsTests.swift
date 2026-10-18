import AppKit
import JavaScriptCore
import Testing
@testable import Sevoflurane

@MainActor
struct SteamMonitorDimensionsTests {
    @Test(arguments: [1.0, 2.0])
    func originalPageRecoversLogicalBoundsAfterApplyingDisplayScale(_ scale: Double) throws {
        let raw = SteamWindow.monitorDimensions(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 48, width: 1920, height: 1007),
            scale: CGFloat(scale), flipLine: 1080,
        )
        #expect(raw["nUsableTop"] == 25 * CGFloat(scale))
        #expect(raw["nUsableHeight"] == 1007 * CGFloat(scale))
        let context = try page(raw)
        try expect(context, [
            "monitor.m_usable.m_nLeft": 0, "monitor.m_usable.m_nTop": 25,
            "monitor.m_usable.m_nWidth": 1920, "monitor.m_usable.m_nHeight": 1007,
            "monitor.m_full.m_nLeft": 0, "monitor.m_full.m_nTop": 0,
            "monitor.m_full.m_nWidth": 1920, "monitor.m_full.m_nHeight": 1080,
            "monitor.m_flDPI": scale,
        ])
    }

    @Test(arguments: [1.0, 2.0])
    func originalPagePreservesNegativeOriginsAndVisibleInsets(_ scale: Double) throws {
        let raw = SteamWindow.monitorDimensions(
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 2560),
            visibleFrame: CGRect(x: -1440, y: 40, width: 1440, height: 2495),
            scale: CGFloat(scale), flipLine: 2160,
        )
        let context = try page(raw)
        try expect(context, [
            "monitor.m_usable.m_nLeft": -1440, "monitor.m_usable.m_nTop": -375,
            "monitor.m_usable.m_nWidth": 1440, "monitor.m_usable.m_nHeight": 2495,
            "monitor.m_full.m_nLeft": -1440, "monitor.m_full.m_nTop": -400,
            "monitor.m_full.m_nWidth": 1440, "monitor.m_full.m_nHeight": 2560,
            "monitor.m_flDPI": scale,
        ])
    }

    @Test
    func originalPagePreservesTheUsableLeftInsetForASideDock() throws {
        let raw = SteamWindow.monitorDimensions(
            frame: CGRect(x: 100, y: 300, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 160, y: 320, width: 1540, height: 955),
            scale: 2, flipLine: 2160,
        )
        try expect(page(raw), [
            "monitor.m_usable.m_nLeft": 160, "monitor.m_usable.m_nTop": 885,
            "monitor.m_usable.m_nWidth": 1540, "monitor.m_usable.m_nHeight": 955,
            "monitor.m_full.m_nLeft": 100, "monitor.m_full.m_nTop": 860,
        ])
    }

    @Test
    func originalToastStackUsesFiniteBoundsAndKeepsItsOwnLifecycle() throws {
        let raw = SteamWindow.monitorDimensions(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 68, width: 1512, height: 889),
            scale: 2, flipLine: 982,
        )
        let context = try page(raw)
        context.evaluateScript(Self.animationEnvironment + "\n" + Self.originalToastAnimation)
        context.evaluateScript("var toasts=[makeToast(),makeToast()]; tick(0);tick(150);tick(300)")
        try #require(context.exception == nil)
        #expect(context.evaluateScript("moves.every(function(m){return m.every(Number.isFinite)})")?.toBool() == true)
        try expect(context, [
            "toasts[0].m_nLastX": 1217, "toasts[1].m_nLastX": 1217,
            "toasts[0].m_nLastY": 736, "toasts[1].m_nLastY": 816,
            "moves[moves.length-1][2]": 2, "shown": 2, "sounds": 2,
        ])
        // NaN !== NaN would resend MoveTo every frame, even at rest.
        context.evaluateScript("var settledMoves=moves.length;tick(400)")
        #expect(context.evaluateScript("moves.length===settledMoves")?.toBool() == true)
        context.evaluateScript("tick(1300);tick(1450);tick(1600)")
        try #require(context.exception == nil)
        try expect(context, ["hidden": 2, "sounds": 2, "toasts[0].m_eState": 4, "toasts[1].m_eState": 4])
    }

    private func page(_ raw: [String: CGFloat]) throws -> JSContext {
        let context = try #require(JSContext())
        context.setObject(raw.mapValues { Double($0) }, forKeyedSubscript: "nativeMonitor" as NSString)
        context.evaluateScript("var monitor=(function(j){return " + Self.originalMonitorConversion + ";})(nativeMonitor)")
        try #require(context.exception == nil)
        return context
    }

    private func expect(_ context: JSContext, _ values: [String: Double]) throws {
        for (expression, expected) in values {
            let result = try #require(context.evaluateScript(expression))
            try #require(context.exception == nil)
            #expect(result.toDouble().isFinite, "\(expression)")
            #expect(result.toDouble() == expected, "\(expression)")
        }
    }

    // Exact conversion expression from Steam sp.js module 71391 and animation
    // function from module 15148; only whitespace is expanded below. Source SHA:
    // 5a28c25041d07e69cf591a414519e0cf970b6884c1a0106659dcd9f1fb9586f9.
    // Dependencies are isolated counters/clock, never real Steam notifications.
    private static let originalMonitorConversion = #"{m_usable:{m_nLeft:Math.round(j.nUsableLeft/j.flHorizontalScale),m_nTop:Math.round(j.nUsableTop/j.flVerticalScale),m_nWidth:Math.ceil(j.nUsableWidth/j.flHorizontalScale),m_nHeight:Math.ceil(j.nUsableHeight/j.flVerticalScale)},m_full:{m_nLeft:Math.round(j.nFullLeft/j.flHorizontalScale),m_nTop:Math.round(j.nFullTop/j.flVerticalScale),m_nWidth:Math.ceil(j.nFullWidth/j.flHorizontalScale),m_nHeight:Math.ceil(j.nFullHeight/j.flVerticalScale)},m_flDPI:j.flHorizontalScale}"#

    private static let animationEnvironment = #"""
    var now=0, performance={now:function(){return now;}}, moves=[], shown=0, hidden=0, sounds=0;
    var v={Pr:function(){return false;}}, ae=283, R=300, Z=300, he=0;
    var y={WU6:{k_EPositionTopLeft:0,k_EPositionTopRight:1,k_EPositionBottomLeft:2,k_EPositionBottomRight:3}};
    var J={wT:function(value,message){if(!value)throw new Error(message);}}, B={Tj:function(){}};
    var u={Tu:{PlayNotificationSound:function(){sounds++;}}};
    function makeToast(){return {
      m_notification:{notificationID:1,nToastDurationMS:1000},m_nToastHeight:80,m_eState:0,m_flLastEventTime:0,
      m_popup:{SteamClient:{Window:{MoveTo:function(x,y,s){moves.push([x,y,s]);},
        ShowWindow:function(){shown++;},HideWindow:function(){hidden++;}}}}
    };}
    function tick(t){now=t;$(toasts,monitor,{position:3,horizontalInset:12,verticalInset:18});}
    """#

    private static let originalToastAnimation = #"""
    function $(Ye,Ft,zt){let St=(0,v.Pr)(),Tt=performance.now();
    for(let oe of Ye)oe.m_eState==3&&Tt>=oe.m_flLastEventTime+Z&&(oe.m_eState=4,oe.m_popup.SteamClient.Window.HideWindow());
    let Ct=0,Lt=[],be=[];
    for(let oe of Ye){let Te=1,Je=!1;
    switch(oe.m_eState){case 0:be.push(oe),oe.m_flLastEventTime=Tt,oe.m_eState=1;
    case 1:Tt>=oe.m_flLastEventTime+R?(oe.m_eState=2,oe.m_flLastEventTime=Tt):Te=(Tt-oe.m_flLastEventTime)/R,Je=!0;
    break;
    case 2:let ue=!1;
    oe.m_notification.fnNotificationResolved?ue=oe.m_notification.fnNotificationResolved():Tt>=oe.m_flLastEventTime+Math.max(oe.m_notification.nToastDurationMS,he)&&(ue=!0),ue&&(oe.m_eState=3,oe.m_flLastEventTime=Tt),Je=!0;
    break;
    case 3:(0,J.wT)(Tt<oe.m_flLastEventTime+Z,"Toast should have been deleted earlier in animation loop"),Te=1-(Tt-oe.m_flLastEventTime)/Z,Je=!0;
    break;
    case 4:break;
    default:(0,J.wT)(!1,"Unknown toast animation state");
    break}Je&&(Lt.push({toast:oe,flPercentDone:Te}),St?Ct+=oe.m_nToastHeight:Ct+=Math.ceil(oe.m_nToastHeight*Te))}if(Lt.length==0)return;
    let it=Ft.m_usable,ot=it.m_nLeft,ht=it.m_nTop,Ze=ot+it.m_nWidth,de=ht+it.m_nHeight,W=Math.min(zt.horizontalInset,it.m_nWidth/4),Be=Math.min(zt.verticalInset,it.m_nHeight/4);
    ot+=W,ht+=Be,Ze-=W,de-=Be;
    let vt=0,We=0;
    switch(zt.position){case y.WU6.k_EPositionTopLeft:vt=ot,We=ht+Ct;
    break;
    case y.WU6.k_EPositionTopRight:vt=Ze,We=ht+Ct;
    break;
    case y.WU6.k_EPositionBottomLeft:vt=ot,We=de-Ct;
    break;
    default:case y.WU6.k_EPositionBottomRight:vt=Ze,We=de-Ct;
    break}for(let oe of Lt){let Te=Math.floor(oe.toast.m_nToastHeight*(1-oe.flPercentDone));
    St&&(Te=0);
    let Je,ue;
    switch(zt.position){case y.WU6.k_EPositionTopLeft:Je=vt,ue=We-Te-oe.toast.m_nToastHeight,We-=oe.toast.m_nToastHeight-Te;
    break;
    case y.WU6.k_EPositionTopRight:Je=vt-ae,ue=We-Te-oe.toast.m_nToastHeight,We-=oe.toast.m_nToastHeight-Te;
    break;
    case y.WU6.k_EPositionBottomLeft:Je=vt,ue=We+Te,We+=oe.toast.m_nToastHeight-Te;
    break;
    default:case y.WU6.k_EPositionBottomRight:Je=vt-ae,ue=We+Te,We+=oe.toast.m_nToastHeight-Te;
    break}(Je!==oe.toast.m_nLastX||ue!==oe.toast.m_nLastY)&&((0,B.Tj)(`moving toast ${oe.toast.m_notification.notificationID} to ${Je}, ${ue}`,oe),oe.toast.m_popup.SteamClient.Window.MoveTo(Je,ue,Ft.m_flDPI),oe.toast.m_nLastX=Je,oe.toast.m_nLastY=ue)}for(let oe of be)oe.m_popup.SteamClient.Window.ShowWindow(),u.Tu.PlayNotificationSound(oe.m_notification)}
    """#
}
