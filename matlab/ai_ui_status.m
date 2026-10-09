function result = ai_ui_status()
% Export the current assistant without reading a new document or sending a request.
app = matlab_ai;
deadline = tic;
while app.IsLoadingModels && toc(deadline) < 25
    pause(0.1);
    drawnow;
end
drawnow;
root = fileparts(fileparts(mfilename('fullpath')));
screenshot = fullfile(root,'output','assistant-ui.png');
exportapp(app.Figure,screenshot);
applied = ~isempty(app.LastApplied) && app.LastApplied.Applied;
result = jsonencode(struct('ok',true,'busy',app.IsBusy, ...
    'status',app.Status.Text,'has_applied_edit',applied,'runtime',app.runtimeStatus, ...
    'modes',{app.Mode.Items},'help_available',~isempty(app.HelpTab) && isvalid(app.HelpTab), ...
    'simulink_available',~isempty(app.SimulinkTab) && isvalid(app.SimulinkTab),'screenshot',screenshot));
end
