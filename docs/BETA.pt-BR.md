# Beta do Tacet

*English: [BETA.md](BETA.md)*

Obrigado por testar o Tacet! Ele oculta os apps da Barra de Menus que você
escolher atrás de uma seta, usando os próprios ajustes "Permitir na Barra de
Menus" do macOS.

## Requisitos

- macOS 27 ou posterior.
- O beta expira 60 dias depois de ser gerado. O menu do clique direito do
  Tacet mostra quantos dias faltam, e o rodapé dos Ajustes, a data. Quando termina, o Tacet para de ocultar e reativa
  tudo.

## Instalação

1. Baixe o `Tacet-<versão>-beta.<n>.zip` pelo seu link do Gumroad. O Safari
   descompacta numa pasta com o Tacet e um guia "How to Install" (senão, dê
   dois cliques no zip).
2. Arraste o **Tacet** para **Aplicativos**.
3. Abra o Tacet em Aplicativos. Na primeira vez, o macOS bloqueia porque o
   beta não é notarizado pela Apple. Para permitir:
   - abra **Ajustes do Sistema › Privacidade e Segurança**, role até a
     mensagem sobre o Tacet, clique em **Abrir Mesmo Assim** e confirme; ou
   - no Terminal: `xattr -dr com.apple.quarantine /Applications/Tacet.app`,
     e abra o Tacet de novo.
4. O Tacet pede uma única coisa: acesso às duas pastas onde o macOS guarda
   os ajustes da Barra de Menus e a ordem dos ícones. Clique em **Conceder
   Acesso…**, mantenha ⌘ pressionado e selecione
   `group.com.apple.controlcenter` e `com.apple.MenuBar` (as únicas pastas
   que dá para clicar) e clique em **Conceder Acesso**.
5. Ative em **Ocultar no Tacet** os apps que você quer ocultar. O Tacet os
   coloca à esquerda da seta sozinho e mantém essa ordem: um ícone arrastado
   para fora do lugar volta.

Clique na seta, ou pressione **⇧⌘<** em qualquer app, para mostrá-los ou
ocultá-los. Nos Ajustes (botão direito na seta › **Ajustes…**) você pode
mudar ou remover esse atalho e ativar **Abrir no Início da Sessão**. Os apps
mostrados se ocultam sozinhos alguns segundos depois que o ponteiro sai da
Barra de Menus (nunca com um menu aberto).

Apps que você quase não usa podem ficar ocultos até nessa hora: nos Ajustes,
passe o mouse sobre o app e clique em ⋯ (ou clique nele com o botão direito)
› **Manter Sempre Oculto**. Clique na seta com ⌥, ou pressione **⌥⇧⌘<**,
para ver esses também; **Voltar para a Lista** devolve um deles à lista.

Os apps ocultos aparecem "desativados" em Ajustes do Sistema › Barra de
Menus. Encerrar o Tacet reativa todos; encerre o Tacet antes de apagá-lo.

## Enviar comentários

Clique com o botão direito na seta do Tacet › **Enviar Comentários…**. Só
são incluídas as versões do Tacet e do macOS.

## Atualizar para um novo beta

Encerre o Tacet (botão direito › Encerrar Tacet), baixe o novo zip e
arraste o Tacet para Aplicativos, substituindo o antigo. Todos os betas são
assinados com o mesmo certificado, então o acesso concedido e os ajustes
continuam. Um novo download precisa de **Abrir Mesmo Assim** (ou do comando
`xattr`) mais uma vez.

As instruções para gerar e publicar um beta estão em [BETA.md](BETA.md)
(em inglês).
