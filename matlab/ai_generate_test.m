function result = ai_generate_test()
checks = struct;
app = MatlabAIAssistant('off');
cleanupApp = onCleanup(@() delete(app));
original = matlab.desktop.editor.getActive;
restoreOriginal = onCleanup(@() activate(original));
try
    waitUntilReady(app,35);
    app.ask('生成 MATLAB 脚本：t 从 0 到 1，步长 0.1；计算 y = sin(t)。用中文注释说明，不绘图、不读文件。','generate','file');
    assert(isempty(app.Transaction));
    checks.no_editor_snapshot_required = true;
    waitUntilReady(app,210);
    assert(isempty(app.LastError),app.LastError);
    assert(~isempty(app.GeneratedText) && contains(app.GeneratedText,'sin'));
    assert(strcmp(app.InsertButton.Enable,'on') && strcmp(app.NewDocumentButton.Enable,'on'));
    assert(isequal(app.Tabs.SelectedTab,app.GeneratedTab));
    checks.real_generation_displayed = true;

    baseline = sprintf('a = 1;\nb = 2;\n');
    doc = matlab.desktop.editor.newDocument(baseline);
    cleanupDoc = onCleanup(@() closeOwned(doc));
    doc.Selection = [2 1 2 1]; doc.makeActive;
    app.insertGenerated(false);
    assert(strcmp(char(doc.Text),baseline),'Preview must not insert before confirmation.');
    app.apply;
    assert(startsWith(char(doc.Text),sprintf('a = 1;\n')) && endsWith(char(doc.Text),sprintf('b = 2;\n')));
    assert(contains(char(doc.Text),app.GeneratedText));
    assert(strcmp(app.InsertButton.Enable,'off'));
    checks.cursor_insertion_preserves_existing_code = true;
    checks.duplicate_insertion_blocked = expectError(@() app.insertGenerated(false),'MatlabAI:NoGeneratedCode');
    app.restore;
    assert(strcmp(char(doc.Text),baseline));
    checks.insertion_restored = true;

    doc.Selection = [1 1 1 4]; doc.makeActive;
    checks.selected_text_not_overwritten = expectError(@() app.insertGenerated(false),'MatlabAI:CursorSelection');
    assert(strcmp(char(doc.Text),baseline));
    app.insertGenerated(true);
    created = app.Transaction.Document;
    cleanupNew = onCleanup(@() closeOwned(created));
    assert(strcmp(char(created.Text),app.GeneratedText));
    assert(~isfile(created.Filename));
    checks.new_unsaved_document = true;
    app.restore;
    assert(isempty(created.Text));
    checks.new_document_insert_restored = true;
    result = jsonencode(struct('ok',true,'checks',checks,'model',app.LastResponse.model));
catch exception
    result = jsonencode(struct('ok',false,'checks',checks,'error',exception.message,'stack',{exception.stack}));
end
end

function waitUntilReady(app,seconds)
started = tic;
while (app.IsLoadingModels || app.IsBusy) && toc(started)<seconds, pause(0.1); end
assert(~app.IsLoadingModels && ~app.IsBusy,'后台任务未及时完成。');
end

function value = expectError(callback,id)
value = false;
try, callback(); catch exception
    assert(strcmp(exception.identifier,id),'Unexpected error: %s',exception.message);
    value = true;
end
assert(value,'Expected action to be rejected.');
end

function closeOwned(doc)
if doc.Opened, doc.closeNoPrompt; end
end

function activate(doc)
if ~isempty(doc) && doc.Opened, doc.makeActive; end
end
