function app = matlab_ai()
%MATLAB_AI Open the MATLAB AI question, preview, apply and restore window.
persistent instance
if isempty(instance) || ~isvalid(instance) || ~isvalid(instance.Figure)
    root=fileparts(fileparts(mfilename('fullpath')));
    configFile=fullfile(root,'config.local.json');
    needsSetup=~isfile(configFile);
    if ~needsSetup
        try
            c=jsondecode(fileread(configFile));
            needsSetup=~isfield(c,'python_executable') || ~isfile(c.python_executable);
            c=ai_backend_config(c);
            needsSetup=needsSetup || (isempty(c.model) && ~strcmp(c.backend,'claude'));
        catch
            needsSetup=true;
        end
    end
    if needsSetup
        matlab_ai_setup(true);
        if nargout, app=[]; end
        return;
    end
    instance = MatlabAIAssistant();
else
    instance = instance.upgradeWindow;
    instance.ensureModelPicker;
    instance.Figure.Visible = 'on';
    figure(instance.Figure);
end
if nargout, app = instance; end
end
