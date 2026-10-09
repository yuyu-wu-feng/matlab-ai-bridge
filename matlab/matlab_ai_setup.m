function wizard=matlab_ai_setup(openAssistant)
%MATLAB_AI_SETUP Detect local programs and configure this project.
% No model call occurs unless the user clicks the explicit live-test button.
if nargin<1, openAssistant=false; end
persistent instance
if isempty(instance) || ~isvalid(instance) || ~isvalid(instance.Figure)
    instance=AISetupWizard('','on',openAssistant);
else
    instance.OpenAssistant=instance.OpenAssistant || openAssistant;
    instance.Figure.Visible='on'; figure(instance.Figure);
end
if nargout, wizard=instance; end
end
