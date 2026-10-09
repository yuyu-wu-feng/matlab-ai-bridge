function result = ai_selftest(includeModel)
% Real MATLAB editor/UI tests; only a synthetic example reaches the model.
if nargin < 1, includeModel = false; end
root = fileparts(fileparts(mfilename('fullpath')));
testFolder = tempname(fullfile(root,'output'));
mkdir(testFolder);
checks = struct;
modelChecks = struct;
original = matlab.desktop.editor.getActive;
restoreActive = onCleanup(@() activate(original));
try
    baseline = sprintf('%% 中文注释\nx = 1:5;\nsquares = x * x;\ndisp(squares);\n');
    doc = matlab.desktop.editor.newDocument(baseline);
    closeFirst = onCleanup(@() closeDoc(doc));
    doc.Selection = [3 1 3 17];
    transaction = AIEditorTransaction(doc,'edit','selection');
    assert(strcmp(transaction.Context,'squares = x * x;'), 'Captured scope: %s, indices [%d %d], selection %s', ...
        jsonencode(transaction.Context), transaction.StartIndex, transaction.EndIndex, mat2str(doc.Selection));
    transaction.propose('squares = x.^2;');
    second = matlab.desktop.editor.newDocument('% unrelated document');
    closeSecond = onCleanup(@() closeDoc(second));
    second.makeActive;
    transaction.apply;
    assert(strcmp(char(doc.Text), strrep(baseline,'squares = x * x;','squares = x.^2;')));
    assert(strcmp(char(second.Text),'% unrelated document'));
    checks.selection_and_tab_switch = true;
    transaction.restore;
    assert(strcmp(char(doc.Text),baseline));
    checks.snapshot_restore = true;
    checks.duplicate_apply_rejected = expectError(@() transaction.apply,'MatlabAI:NoProposal');

    transaction = AIEditorTransaction(doc,'edit','file');
    transaction.propose(strrep(baseline,'1:5','1:10'));
    doc.Text = [baseline '% typing while waiting'];
    checks.concurrent_edit_rejected = expectError(@() transaction.apply,'MatlabAI:Conflict');
    assert(endsWith(char(doc.Text),'% typing while waiting'));
    doc.Text = baseline;

    transaction = AIEditorTransaction(doc,'explain','file');
    checks.explanation_cannot_write = expectError(@() transaction.propose('x = 99;'),'MatlabAI:ExplainReadOnly');
    transaction = AIEditorTransaction(doc,'edit','file');
    checks.malformed_proposal_rejected = expectError(@() transaction.propose('```matlab'),'MatlabAI:InvalidResponse');

    doc.Selection = [4 1 4 1];
    transaction = AIEditorTransaction(doc,'complete','cursor');
    transaction.propose(sprintf('%% inserted\n'));
    transaction.apply;
    assert(strcmp(char(doc.Text), strrep(baseline,'disp(squares);',sprintf('%% inserted\ndisp(squares);'))));
    transaction.restore;
    checks.cursor_insertion = true;

    path = fullfile(testFolder,'中文测试.m');
    doc.saveAs(path);
    saved = char(doc.Text);
    disk = fileread(path);
    doc.Selection = [3 1 3 17];
    transaction = AIEditorTransaction(doc,'edit','selection');
    transaction.propose('squares = x.^2;');
    transaction.apply;
    assert(strcmp(fileread(path),disk));
    assert(doc.Modified);
    checks.saved_file_no_implicit_save = true;
    checks.line_endings_and_chinese = strcmp(char(doc.Text),strrep(saved,'squares = x * x;','squares = x.^2;'));
    doc.Text = [char(doc.Text) '% user change after apply'];
    checks.restore_conflict_rejected = expectError(@() transaction.restore,'MatlabAI:Conflict');
    doc.Text = saved;

    transaction = AIEditorTransaction(doc,'edit','file');
    transaction.propose([saved '% extra']);
    fid = fopen(path,'a'); fprintf(fid,'\n%% external change'); fclose(fid);
    checks.external_file_change_rejected = expectError(@() transaction.apply,'MatlabAI:DiskConflict');
    % The API may reload the changed disk content; only this owned file is saved.
    doc.Text = saved; doc.save;
    transaction = AIEditorTransaction(doc,'edit','file');
    transaction.propose([saved '% extra']);
    doc.saveAs(fullfile(testFolder,'renamed.m'));
    checks.renamed_document_rejected = expectError(@() transaction.apply,'MatlabAI:Renamed');
    transaction = AIEditorTransaction(doc,'edit','file');
    transaction.propose([saved '% extra']);
    doc.closeNoPrompt;
    checks.closed_document_rejected = expectError(@() transaction.apply,'MatlabAI:Closed');

    escaped = ai_diff_html('x = 1;', sprintf('x = 2;\n%% <script>alert(1)</script>'));
    assert(~contains(escaped,'<script>') && contains(escaped,'&lt;script&gt;'));
    checks.diff_html_escaped = true;

    app = MatlabAIAssistant('off');
    closeApp = onCleanup(@() delete(app));
    started = tic;
    while app.IsLoadingModels && toc(started)<30, pause(0.1); end
    assert(~app.IsLoadingModels,'Model catalog did not finish loading.');
    checks.ui_constructed = isvalid(app.Figure);
    if includeModel
        demo = matlab.desktop.editor.newDocument(baseline);
        closeDemo = onCleanup(@() closeDoc(demo));
        demo.Selection = [3 1 3 17]; demo.makeActive;
        app.ask('将选区中的矩阵乘法改为向量逐元素平方。替换为 squares = x.^2;。简短解释。', 'edit','selection');
        assert(app.IsBusy);
        demo.Text = [baseline '% user typed during network request'];
        second.makeActive;
        waitApp(app);
        assert(isempty(app.LastError), app.LastError);
        assert(strcmp(app.ApplyButton.Enable,'on'));
        assert(contains(app.Transaction.Replacement,'x.^2'));
        assert(contains(app.Diff.HTMLSource,"class='add'"));
        modelChecks.real_model_response_and_preview = true;
        modelChecks.waiting_does_not_freeze_editor = true;
        modelChecks.real_response_conflict_blocked = expectError(@() app.apply,'MatlabAI:Conflict');
        demo.Text = baseline;
        app.apply;
        assert(strcmp(char(demo.Text),strrep(baseline,'squares = x * x;','squares = x.^2;')));
        assert(strcmp(char(second.Text),'% unrelated document'));
        modelChecks.real_response_applied_to_original_tab = true;
        app.restore;
        assert(strcmp(char(demo.Text),baseline));
        modelChecks.real_response_restored = true;

        demo.makeActive;
        app.ask('简短解释代码中为什么 x * x 不适合这个行向量。','explain','file');
        waitApp(app);
        assert(isempty(app.LastError),app.LastError);
        assert(strcmp(char(demo.Text),baseline) && strcmp(app.ApplyButton.Enable,'off'));
        modelChecks.real_explanation_read_only = true;

        app.ask('解释这段代码。','explain','file');
        app.cancel;
        waitApp(app);
        assert(strcmp(char(demo.Text),baseline));
        assert(strcmp(app.ApplyButton.Enable,'off'));
        modelChecks.cancellation_no_write = true;
    end
    names = fieldnames(checks);
    for k=1:numel(names), assert(checks.(names{k}),names{k}); end
    result = jsonencode(struct('ok',true,'release',version('-release'), ...
        'editor_ui_checks',checks,'real_model_checks',modelChecks, ...
        'real_model_tested',includeModel,'native_undo_tested',false));
catch exception
    result = jsonencode(struct('ok',false,'editor_ui_checks',checks, ...
        'real_model_checks',modelChecks,'error_id',exception.identifier, ...
        'error',exception.message,'stack',{exception.stack}));
end
end

function value = expectError(callback, id)
value = false;
try, callback(); catch exception
    assert(strcmp(exception.identifier,id), 'Expected %s, got %s: %s',id,exception.identifier,exception.message);
    value = true;
end
assert(value,'Expected operation to be rejected.');
end

function waitApp(app)
started = tic;
while app.IsBusy && toc(started)<210, pause(0.1); end
assert(~app.IsBusy,'Model request did not finish within the test timeout.');
end

function closeDoc(doc)
if doc.Opened, doc.closeNoPrompt; end
end

function activate(doc)
if ~isempty(doc) && doc.Opened, doc.makeActive; end
end
