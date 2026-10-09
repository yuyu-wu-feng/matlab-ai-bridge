function result=ai_setup_test()
% Exercise the real asynchronous wizard with an isolated configuration.
root=fileparts(fileparts(mfilename('fullpath')));
original=fileread(fullfile(root,'config.local.json'));
folder=tempname(fullfile(root,'output')); mkdir(folder);
cleanup=onCleanup(@() rmdir(folder,'s'));
configFile=fullfile(folder,'config.json');
w=AISetupWizard(configFile,'off',false);
wc=onCleanup(@() delete(w));
assert(~w.Saved && ~isfile(configFile));
w.detect; waitReady(w,90);
assert(w.LastReport.ok && strcmp(w.LastReport.stage,'discovery'));
assert(~isfile(configFile),'检测不应写入配置');
assert(~w.LastReport.model_called);
assert(~isempty(w.Python.Value));
% Select the installed backend without invoking a model.
c=jsondecode(original); w.Backend.Value='codex'; w.chooseBackend;
if isempty(w.Agent.Value), w.Agent.Value=c.codex_executable; end
w.Model.Value=c.model;
w.First.Value=120; w.Idle.Value=90; w.Total.Value=600;
w.save; waitReady(w,40); assert(w.Saved && w.LastReport.ok);
saved=jsondecode(fileread(configFile)); assert(saved.first_output_timeout_seconds==120);
assert(strcmp(saved.python_executable,w.Python.Value));
w.check(false); waitReady(w,40);
assert(w.LastReport.ok && strcmp(w.LastReport.stage,'installation_checked'));
assert(~w.LastReport.model_called);
% The auto-detected executable must also work in the actual assistant catalog.
app=MatlabAIAssistant('off','',configFile);
appCleanup=onCleanup(@() delete(app));
t=tic;
while app.IsLoadingModels && toc(t)<40, pause(0.1); end
assert(~app.IsLoadingModels && strcmp(app.ModelSource,'codex'),'自动检测入口未成功读取模型目录');
delete(app);
w.Total.Value=10; w.dirty; w.save; waitReady(w,40);
assert(~w.Saved && ~w.LastReport.ok);
saved=jsondecode(fileread(configFile)); assert(saved.timeout_seconds==600);
w.Total.Value=600; w.save; waitReady(w,40); assert(w.Saved);
backups=dir(fullfile(folder,'output','setup-backups','*.json')); assert(~isempty(backups));
exportapp(w.Figure,fullfile(root,'output','setup-wizard-ui.png'));
% Public documentation illustration uses generic paths, not local identity.
values={w.Python.Value,w.Agent.Value,w.Node.Value,w.Model.Value,w.Status.Value};
w.Python.Value='C:\Python312\python.exe'; w.Agent.Value='C:\Tools\codex.exe';
w.Node.Value=''; w.Model.Value='你的模型 ID';
w.Status.Value={'界面示意：请使用你自己电脑上的程序路径和可用模型 ID。';'检测和保存不调用模型；测试模型连接可能产生用量。'};
exportapp(w.Figure,fullfile(root,'output','setup-wizard-guide.png'));
w.Python.Value=values{1}; w.Agent.Value=values{2}; w.Node.Value=values{3}; w.Model.Value=values{4}; w.Status.Value=values{5};
% Cancellation never writes a config during discovery, and remains restartable.
w.detect; w.cancel; assert(~w.Busy);
w.detect; waitReady(w,90); assert(w.LastReport.ok);
assert(strcmp(original,fileread(fullfile(root,'config.local.json'))),'不得修改用户配置');
result=jsonencode(struct('ok',true,'discovery',true,'save',true,'installation_check',true, ...
    'reject_invalid_wait',true,'backup',true,'cancel_restart',true,'user_config_unchanged',true, ...
    'detected_entry_catalog',true,'model_called',false));
disp(result);
fid=fopen(fullfile(root,'output','test-setup.json'),'w','n','UTF-8');
fwrite(fid,unicode2native(result,'UTF-8'),'uint8'); fclose(fid);
end
function waitReady(w,seconds)
t=tic;
while w.Busy && toc(t)<seconds, pause(0.1); end
assert(~w.Busy,'配置操作超时');
end
