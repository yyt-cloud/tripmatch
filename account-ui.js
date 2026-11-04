// Reuse the existing page shell and invite flow; production passwords stay in Auth.
let accountMode = 'login';
let pendingPhone = '';
function phoneVerificationPage() {
  shell('<form class="login-card" onsubmit="confirmPhone(event)"><h2>验证手机号</h2><p>请输入注册手机号收到的短信验证码。</p><input id="phoneCode" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required><button class="btn btn-primary">验证并登录</button><button type="button" class="btn btn-quiet" onclick="loginPage()">返回</button></form>');
}
async function confirmPhone(e) {
  e.preventDefault();e.submitter.disabled=true;
  try { currentUser=await cloud.verifyPhone(pendingPhone,document.querySelector('#phoneCode').value.trim());localStorage.setItem(USER_STORAGE,JSON.stringify(currentUser));await resumeAfterLogin(); }
  catch(error){toast(error.message);e.submitter.disabled=false;}
}
loginPage = function () {
  const register = accountMode === 'register';
  shell(`<section class="login-layout"><div class="login-intro"><div class="eyebrow">TripMatch 账号</div><h1>一个账号，保留每一次出发。</h1><p>${cloud.enabled?'登录后恢复你发起和参与的活动。':'本地体验只保存在当前浏览器，请使用测试密码。'}</p></div><form class="login-card" onsubmit="passwordLogin(event)"><div class="actions"><button type="button" class="btn ${register?'btn-secondary':'btn-primary'}" onclick="accountMode='login';loginPage()">登录</button><button type="button" class="btn ${register?'btn-primary':'btn-secondary'}" onclick="accountMode='register';loginPage()">注册</button></div><h2>${register?'创建账号':'欢迎回来'}</h2><p>${sessionStorage.getItem('tripmatch-pending-invite')?'登录后继续填写邀请活动。':'使用自己的账号查看活动。'}</p><div class="field"><label>手机号（中国大陆 +86）</label><input id="account" type="tel" autocomplete="username" inputmode="numeric" pattern="1[0-9]{10}" maxlength="11" required></div>${register?'<div class="field"><label>昵称</label><input id="accountName" maxlength="20" required></div>':''}<div class="field"><label>密码</label><input id="accountPassword" type="password" minlength="8" autocomplete="${register?'new-password':'current-password'}" required></div><button class="btn btn-primary login-submit">${register?'注册并继续':'登录'}</button></form></section>`);
};
async function passwordLogin(e) {
  e.preventDefault(); const button=e.submitter;button.disabled=true;
  const account=document.querySelector('#account').value.trim(),password=document.querySelector('#accountPassword').value,nickname=document.querySelector('#accountName')?.value.trim()||'';
  try {
    const user=cloud.enabled?await cloud.passwordAuth(account,password,nickname,accountMode==='register'):await (accountMode==='register'?LocalAuth.register(account,password,nickname):LocalAuth.login(account,password));
    if(user.needsConfirmation){pendingPhone=account;phoneVerificationPage();return;}
    currentUser=user;localStorage.setItem(USER_STORAGE,JSON.stringify(user));await resumeAfterLogin();
  }catch(error){toast(error.message);button.disabled=false;}
}
resumeAfterLogin = async function () {
  state={...state,tripId:null,preferenceId:null,groupId:null,selectedDests:[],selectedStyles:[]};
  if(cloud.enabled){db={trips:[],preferences:[],groups:[],votes:[]};await refreshCloudData();}
  const code=sessionStorage.getItem('tripmatch-pending-invite');
  if(code)await openInvite(code);else await go('home');
};
refreshCloudData = async function () {
  if(!cloud.enabled||!currentUser)return;
  const userId=currentUser.id;
  try {
    const dashboard=await cloud.userDashboard();
    if(currentUser?.id!==userId)return;
    const next={trips:[],preferences:[],groups:[],votes:db.votes.filter(v=>v.userId===userId)};
    (dashboard.trips||[]).forEach(t=>{mergeById(next.trips,[t]);mergeById(next.preferences,t.preferences||[]);mergeById(next.groups,t.groups||[]);});
    (dashboard.participations||[]).forEach(item=>{mergeById(next.trips,[item.trip]);mergeById(next.preferences,[...(item.preferences||[]),item.preference]);mergeById(next.groups,item.groups||[]);});
    db=next;save();
  }catch(error){toast('同步失败：'+error.message);}
};
openInvite = async function (code) {
  if(!currentUser){sessionStorage.setItem('tripmatch-pending-invite',code);return loginPage();}
  try {
    const trip=cloud.enabled?await cloud.getTrip(code):db.trips.find(t=>t.id===code);
    if(!trip)throw new Error('活动不存在，请检查邀请链接');
    mergeById(db.trips,[trip]);save();state.role='participant';state.tripId=trip.id;
    sessionStorage.removeItem('tripmatch-pending-invite');await go('form');
  }catch(error){toast(error.message);}
};
if(!currentUser)loginPage();
