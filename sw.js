// 푸시 알림 전용 서비스 워커 (캐시·오프라인 기능은 없음)
// 사파리(아이폰·아이패드)는 푸시가 올 때마다 알림을 안 띄우면 구독을 끊어 버려서 항상 띄움 (index.html 의 PUSH_ALWAYS 와 같은 식)
var PUSH_ALWAYS=/AppleWebKit/.test(navigator.userAgent)&&!/Chrome|Android/.test(navigator.userAgent);
function diaryWindows(){return self.clients.matchAll({type:'window',includeUncontrolled:true});}

self.addEventListener('push',function(e){
  var d={};
  try{d=e.data.json();}catch(err){}
  e.waitUntil(diaryWindows().then(function(list){
    // 다이어리를 지금 보고 있으면 화면 안 알림이 대신 뜸
    if(!PUSH_ALWAYS&&list.some(function(c){return c.focused;})) return;
    return self.registration.showNotification(d.title||'다이어리',{body:d.body||'새 메시지가 왔어요',tag:'chat',renotify:true});
  }));
});

// 알림을 누르면 열려 있는 다이어리를 앞으로 가져오고(없으면 새로 열고) 대화 창으로 보냄
self.addEventListener('notificationclick',function(e){
  e.notification.close();
  e.waitUntil(diaryWindows().then(function(list){
    if(list[0]){list[0].postMessage('open-chat');return list[0].focus();}
    return self.clients.openWindow(self.registration.scope+'#chat');
  }));
});
