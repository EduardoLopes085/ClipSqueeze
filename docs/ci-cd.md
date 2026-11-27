# CI/CD do ClipSqueeze

O workflow do GitHub Actions roda em pull requests para `development` e `main`, em pushes nessas branches e em tags iniciadas por `v`. Na aba **Actions**, execute-o sem preencher `release_tag` para rodar apenas a CI.

## Validação

- O `actionlint` verifica o workflow. O Dependabot abre PRs semanais para atualizar as GitHub Actions fixadas por SHA.
- A matriz no Windows valida a sintaxe dos scripts, confere a versão do pacote e testa a compressão em CPU com FFmpeg no Windows PowerShell 5.1 e no PowerShell 7.
- O teste de instalação usa uma pasta temporária para verificar instalação, reinstalação, atualização, desinstalação e recuperação após falhas. Ele simula rede, WinGet e alterações na política de execução.
- Os testes geram um vídeo sintético e verificam vídeo HEVC, áudio AAC, resolução e duração dos resultados. Um dos casos também verifica o limite de tamanho em bytes. Para uma alteração em AMF ou NVENC, registre no PR o teste feito em uma máquina com a GPU correspondente.
- Para exigir a CI antes de mesclar, configure o check **CI** como obrigatório nas regras de `main` e `development` no GitHub.

Para reproduzir as verificações no Windows com `ffmpeg` e `ffprobe` no PATH, execute da raiz do repositório. Use uma pasta de saída nova para cada pacote.

```powershell
& ./.github/scripts/New-ReleasePackage.ps1 -OutputDirectory (Join-Path $env:TEMP "ClipSqueeze-package-$([guid]::NewGuid())")
& ./.github/scripts/Test-InstallationLifecycle.ps1
& ./.github/scripts/Test-Compression.ps1
```

## Comentário de revisão no pull request

Use este formato ao pedir uma alteração ou registrar o resultado de uma verificação.

```markdown
**Observação:** descreva o que encontrou e indique o arquivo ou a etapa afetada.

**Como reproduzir:** inclua o comando e o resultado observado, quando aplicável.

**Alteração sugerida:** indique o que precisa ser ajustado antes do merge, se houver.
```

## Publicação

1. No ambiente `release` do GitHub, permita somente a branch `main`, exija revisão manual e defina a variável `RELEASE_SIGNER_SHA256` com a impressão SHA-256 pública do certificado oficial. Restrinja a criação de tags `v*` aos responsáveis pela release. [Ambientes e aprovações](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments)
2. Atualize `applicationVersion` em `config.json` e `$script:ApplicationVersion` em `install.ps1` para a mesma versão `MAJOR.MINOR.PATCH`. Mescle o commit em `main` e crie a tag nesse commit. O exemplo usa a versão `0.1.0`.

   ```powershell
   git fetch origin main
   git tag -a v0.1.0 origin/main -m "ClipSqueeze v0.1.0"
   git push origin refs/tags/v0.1.0
   ```

3. Em um Windows dedicado à assinatura, use um checkout limpo dessa tag e um certificado de assinatura de código confiável em `Cert:\CurrentUser\My`. O comando usa a chave pelo Windows e funciona com chaves não exportáveis que oferecem suporte ao Authenticode. O parâmetro é o thumbprint de 40 caracteres usado pelo repositório de certificados do Windows para localizar o certificado. O comando imprime separadamente o SHA-256 de 64 caracteres para configurar no GitHub.

   ```powershell
   git switch --detach v0.1.0
   $package = Join-Path $env:TEMP "ClipSqueeze-release-$([guid]::NewGuid())"
   & ./.github/scripts/New-ReleasePackage.ps1 -Tag v0.1.0 -OutputDirectory $package -SigningCertificateThumbprint '<thumbprint de 40 caracteres>'
   gh release create v0.1.0 --repo EduardoLopes085/ClipSqueeze --verify-tag --draft --generate-notes (Join-Path $package 'ClipSqueeze.ps1') (Join-Path $package 'ClipSqueeze-v0.1.0.zip') (Join-Path $package 'SHA256SUMS.txt')
   ```

4. Execute **ClipSqueeze CI/CD** na branch `main` com `release_tag` igual à tag do rascunho. Depois da CI e da aprovação, o job compara a tag com o commit testado, verifica o manifesto, a correspondência com o código-fonte, o certificado e os carimbos de tempo, e publica o rascunho. A chave privada permanece na estação de assinatura.

## Atualizações oficiais

O `update.ps1` do ZIP oficial já contém a impressão SHA-256 do certificado e consulta `EduardoLopes085/ClipSqueeze`. Execute `./update.ps1` na pasta que contém o atualizador. Quem usa uma cópia anterior do atualizador deve substituí-la pela cópia do ZIP oficial. Para verificar uma atualização a partir de um checkout, informe `-TrustedSignerSha256` com uma impressão obtida por um canal confiável.

Ao trocar o certificado, distribua o novo atualizador por um canal confiável antes de publicar uma atualização assinada pela nova chave. As cópias que fixaram o certificado anterior recusarão o novo assinante.
