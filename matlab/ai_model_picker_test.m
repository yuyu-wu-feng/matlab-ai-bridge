function result = ai_model_picker_test()
% Verify real model discovery, widget selection, refresh and a selected model request.
checks = struct;
app = MatlabAIAssistant('off');
cleanupApp = onCleanup(@() delete(app));
try
    waitModels(app);
    assert(isa(app.Model,'matlab.ui.control.DropDown'));
    assert(strcmp(app.Model.Editable,'off'));
    assert(numel(app.Model.ItemsData)>1,'Expected multiple locally discovered models.');
    checks.dropdown_uses_discovered_models = true;
    originalModel = app.Model.Value;
    ids = app.Model.ItemsData;
    alternative = find(~strcmp(ids,originalModel) & contains(ids,'sol'),1);
    if isempty(alternative), alternative = find(~strcmp(ids,originalModel),1); end
    selected = ids{alternative};
    app.Model.Value = selected;
    app.refreshModels;
    waitModels(app);
    assert(strcmp(app.Model.Value,selected));
    checks.refresh_preserves_selection = true;
    assert(strcmp(app.ModelRefreshButton.Enable,'on'));
    checks.refresh_completes_in_background = true;

    originalDoc = matlab.desktop.editor.getActive;
    restoreOriginal = onCleanup(@() activate(originalDoc));
    doc = matlab.desktop.editor.newDocument(sprintf('%% 模型下拉框测试\nx = 1;\n'));
    closeDoc = onCleanup(@() closeOwned(doc));
    doc.makeActive;
    before = char(doc.Text);
    app.ask('请用一句中文解释这行赋值，不修改代码。','explain','file');
    assert(strcmp(app.Model.Enable,'off') && strcmp(app.ModelRefreshButton.Enable,'off'));
    checks.model_locked_during_request = true;
    started = tic;
    while app.IsBusy && toc(started)<210, pause(0.1); end
    assert(~app.IsBusy,'Model request timed out.');
    assert(isempty(app.LastError),app.LastError);
    assert(strcmp(app.LastResponse.model,selected));
    assert(strcmp(char(doc.Text),before));
    checks.selected_model_real_request = true;
    checks.no_editor_write = true;
    result = jsonencode(struct('ok',true,'checks',checks,'source',app.ModelSource, ...
        'models',{ids},'tested_model',selected));
catch exception
    result = jsonencode(struct('ok',false,'checks',checks,'error',exception.message,'stack',{exception.stack}));
end
end

function waitModels(app)
started = tic;
while app.IsLoadingModels && toc(started)<35, pause(0.1); end
assert(~app.IsLoadingModels,'Model discovery timed out.');
end

function closeOwned(doc)
if doc.Opened, doc.closeNoPrompt; end
end

function activate(doc)
if ~isempty(doc) && doc.Opened, doc.makeActive; end
end
