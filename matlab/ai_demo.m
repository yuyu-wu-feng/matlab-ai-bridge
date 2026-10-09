function result = ai_demo()
% Open an owned demo document and leave the assistant ready for the user.
root = fileparts(fileparts(mfilename('fullpath')));
example = fullfile(root,'examples','vector_square.m');
doc = matlab.desktop.editor.openDocument(example);
doc.makeActive;
doc.Selection = [3 1 3 17];
app = matlab_ai;
started = tic;
while app.IsLoadingModels && toc(started)<30, pause(0.1); end
app.ask('将选中的矩阵乘法改为向量逐元素平方，并解释修改原因。','edit','selection');
started = tic;
while app.IsBusy && toc(started)<210, pause(0.1); end
assert(~app.IsBusy,'模型请求未结束。');
assert(isempty(app.LastError),app.LastError);
figure(app.Figure);
report = struct('ok',true,'example',example,'message','真实模型预览已打开，尚未应用；可以点击应用修改。');
try
    drawnow;
    screenshot = fullfile(root,'output','assistant-ui.png');
    exportapp(app.Figure,screenshot);
    report.screenshot = screenshot;
catch exception
    report.screenshot_error = exception.message;
end
result = jsonencode(report);
end
