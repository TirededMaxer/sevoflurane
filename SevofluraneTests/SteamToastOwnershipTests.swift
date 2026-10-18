import JavaScriptCore
import Testing
@testable import Sevoflurane

@MainActor
struct SteamToastOwnershipTests {
    @Test
    func duplicateGeneralQueueNeverReplaysAfterDesktopToast() throws {
        let context = try fixture()
        #expect(context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)?.toString() == "installed")
        context.evaluateScript("""
        var desktop=makeStore(), original={notificationID:42,eSource:1,eType:10};
        desktop.m_rgNotificationToasts.push(original);desktop.DispatchNextToast();
        NotificationStore.m_rgNotificationToasts.push(original);NotificationStore.DispatchNextToast();
        var shown=desktop.PopNextToastNotification(0);desktop.PlayNotificationSound(shown);
        // Opening the game's original overlay after the desktop presentation
        // must not replay a second copy of the same original notification.
        var replay=NotificationStore.PopNextToastNotification(730);
        NotificationStore.PlayNotificationSound(original);
        """)
        try check(context, "shown===original && replay===undefined && desktop.sounds.length===1 && NotificationStore.sounds.length===0")
        try check(context, "NotificationStore.m_rgNotificationToasts.length===0 && NotificationStore.tray===originalTray")
    }

    @Test
    func originalGameIntroductionKeepsItsOwnQueueAndSound() throws {
        let context = try fixture()
        _ = context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)
        context.evaluateScript("""
        var introduction={notificationID:51,eSource:1,eType:99};
        var queue=[introduction];NotificationStore.m_mapAppOverlayToasts.set(730,queue);
        var other={notificationID:52};NotificationStore.m_mapAppOverlayToasts.set(440,[other]);
        var shown=NotificationStore.PopNextToastNotification(730);
        NotificationStore.PlayNotificationSound(shown);
        """)
        try check(context, "shown===introduction && queue.length===0 && NotificationStore.sounds[0]===introduction")
        try check(context, "NotificationStore.m_mapAppOverlayToasts.get(440)[0]===other && NotificationStore.sounds.length===1")
        #expect(context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)?.toString() == "already installed")
    }

    @Test
    func desktopBacklogRemainsInOriginalOrderAcrossGameTransitions() throws {
        let context = try fixture()
        _ = context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)
        context.evaluateScript("""
        var desktop=makeStore();
        for(var id=1;id<=6;id++){
          var notification={notificationID:id};
          desktop.m_rgNotificationToasts.push(notification);desktop.DispatchNextToast();
          NotificationStore.m_rgNotificationToasts.push(notification);NotificationStore.DispatchNextToast();
        }
        // WebKit remains the one general-toast presenter above games as well
        // as the desktop; a focus transition cannot discard its pending FIFO.
        var shown=[];
        while(desktop.m_rgNotificationToasts.length){
          var item=desktop.PopNextToastNotification(0);shown.push(item.notificationID);desktop.PlayNotificationSound(item);
        }
        """)
        try check(context, "JSON.stringify(shown)==='[1,2,3,4,5,6]' && desktop.sounds.length===6 && NotificationStore.m_rgNotificationToasts.length===0")
    }

    @Test
    func activeOriginalToastMustFinishBeforeWebKitCanBoot() throws {
        let context = try fixture()
        context.evaluateScript("NotificationStore.active=true;NotificationStore.m_rgNotificationToasts.push({notificationID:8})")
        #expect(context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)?.toString() == "draining")
        try check(context, "NotificationStore.active && NotificationStore.m_rgNotificationToasts.length===0")
        // Clearing the pending queue cannot pretend that React's local toast
        // state has closed. Repeated handoff checks wait for original dismiss.
        #expect(context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)?.toString() == "draining")
        context.evaluateScript("NotificationStore.active=false")
        #expect(context.evaluateScript(SteamPresentation.originalGameToastOwnershipScript)?.toString() == "already installed")
    }

    private func fixture() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window=this;
        function makeStore(){return {
          m_rgNotificationToasts:[],m_mapAppOverlayToasts:new Map(),tray:[],sounds:[],current:null,active:false,
          BAnyContextRenderingToasts:function(){return this.active},
          // Queue behavior from Steam sp.js module 7474. The presentation
          // adapter must preserve its per-app priority and general FIFO.
          PopNextToastNotification:function(oe){if(oe){let Te=this.m_mapAppOverlayToasts.get(oe);if(Te&&Te.length>0)return Te.shift()}if(this.m_rgNotificationToasts.length===0)return;let Te=this.m_rgNotificationToasts.shift();return this.DispatchNextToast(),Te},
          ClearAllToastNotifications:function(){this.m_rgNotificationToasts.length&&(this.m_rgNotificationToasts=[],this.DispatchNextToast())},
          DispatchNextToast:function(){this.current=this.m_rgNotificationToasts[0]||null},
          PlayNotificationSound:function(item){this.sounds.push(item)}
        }}
        var NotificationStore=makeStore(),originalTray=NotificationStore.tray;
        """)
        try #require(context.exception == nil)
        return context
    }

    private func check(_ context: JSContext, _ expression: String) throws {
        try #require(context.exception == nil)
        #expect(context.evaluateScript(expression)?.toBool() == true, "\(expression)")
        try #require(context.exception == nil)
    }
}
