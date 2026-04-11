% 0_csi_build_windows.m
% Numbered pipeline entrypoint.
% The implementation lives in csi_build_windows.m and has been updated to
% export domain-aware metadata per single-receiver window.
%
% Usage example:
%   csi_build_windows('in','/path/to/raw','out','/path/to/windows');
%
% NOTE:
%   This stage exports one receiver per sample window. It does NOT pair or
%   fuse A/B windows.
