function result = ai_responsiveness_test()
% Use an isolated, hidden assistant; never change the user's draft or editor.
app=MatlabAIAssistant('off');
cleanup=onCleanup(@() delete(app));
checks=struct;
try
    waitReady(app,30);
    app.ask('生成最短 MATLAB 脚本：a=5，计算 a 的阶乘并赋给 result。','generate','file');
    waitReady(app,75);
    checks.request_returns_control=~app.IsBusy;
    checks.generation_error=app.LastError;
    checks.real_generation=isempty(app.LastError) && ~isempty(app.GeneratedText);
    if checks.real_generation, checks.generation_seconds=app.LastResponse.elapsed_seconds; end
    % Simulate the ordinary UI polling timer failing while a request is active.
    app.ask('生成 MATLAB 代码：x=1。','generate','file');
    status=app.runtimeStatus;
    poll=timerfindall('Name',status.poll_timer_name);
    assert(isscalar(poll));
    stop(poll);
    started=tic;
    app.cancel;
    waitReady(app,12);
    checks.cancel_seconds=toc(started);
    checks.watchdog_recovers_stopped_poll=~app.IsBusy && strcmp(app.SendButton.Enable,'on');
    checks.cancelled_code_not_insertable=strcmp(app.InsertButton.Enable,'off');
    assert(checks.watchdog_recovers_stopped_poll && checks.cancelled_code_not_insertable);
    result=jsonencode(struct('ok',checks.real_generation,'checks',checks));
catch exception
    result=jsonencode(struct('ok',false,'checks',checks,'error',exception.message));
end
end

function waitReady(app,seconds)
started=tic;
while (app.IsBusy || app.IsLoadingModels) && toc(started)<seconds, pause(0.1); end
assert(~app.IsBusy && ~app.IsLoadingModels,'助手未在等待上限内恢复。');
end
