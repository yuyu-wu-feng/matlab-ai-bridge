function result=ai_backend_settings_test(useModel)
% Isolated settings file and invisible UI; do not alter real preferences.
if nargin<1, useModel=false; end
root=fileparts(fileparts(mfilename('fullpath')));
folder=tempname(fullfile(root,'output')); mkdir(folder);
cleanup=onCleanup(@() rmdir(folder,'s'));
configFile=fullfile(folder,'config.json');
copyfile(fullfile(root,'config.local.json'),configFile);
app=MatlabAIAssistant('off','',configFile);
appCleanup=onCleanup(@() delete(app));
waitReady(app,35);
checks=struct;
assert(~isempty(app.SettingsTab)); checks.settings_tab=true;
app.configureBackend(struct('timeout_seconds',600,'first_output_timeout_seconds',120,'idle_timeout_seconds',90));
c=jsondecode(fileread(configFile)); assert(c.timeout_seconds==600 && c.first_output_timeout_seconds==120);
checks.persist_wait_limits=true;
try
    app.configureBackend(struct('timeout_seconds',30));
    error('Test:MissingError','应拒绝总等待小于首次等待');
catch e
    assert(strcmp(e.identifier,'MatlabAI:Configuration'));
end
checks.inconsistent_wait_rejected=true;
app.configureBackend(struct('backend','claude','model','', 'first_output_timeout_seconds',0,'idle_timeout_seconds',0));
c=app.backendSettings; assert(strcmp(c.model,'__default__') && c.first_output_timeout_seconds==0);
checks.claude_default_and_disabled_wait=true;
app.configureBackend(struct('backend','codex','model',c.backend_models.codex));
checks.backend_model_preserved=strcmp(app.Model.Value,c.backend_models.codex);
app.openSettings;
exportapp(app.Figure,fullfile(root,'output','backend-settings-ui.png'));
if useModel
    app.ask('生成最短 MATLAB 代码：x=2，然后 y=x^2。','generate','file');
    waitReady(app,150);
    checks.real_generation=isempty(app.LastError) && ~isempty(app.GeneratedText);
    checks.real_error=app.LastError;
    assert(checks.real_generation,app.LastError);
end
result=jsonencode(struct('ok',true,'checks',checks)); disp(result);
fid=fopen(fullfile(root,'output','test-backend-settings.json'),'w','n','UTF-8');
fwrite(fid,unicode2native(result,'UTF-8'),'uint8'); fclose(fid);
end

function waitReady(app,seconds)
started=tic;
while (app.IsBusy || app.IsLoadingModels) && toc(started)<seconds, pause(0.1); end
assert(~app.IsBusy && ~app.IsLoadingModels,'助手等待超时');
end
